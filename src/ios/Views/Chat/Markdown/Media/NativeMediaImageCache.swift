//
//  NativeMediaImageCache.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Media plumbing shared by the renderer and the image / video attachments.
//
//  - nativeImageExts / nativeVideoExts / nativeAudioExts: decide whether a link
//    is rendered as an image, video or audio attachment (MarkdownNSRenderer).
//  - NativeMediaImageCache: decoded bitmaps plus a persisted record of each
//    image's pixel size, so ImageAttachment can reserve its final height before
//    the bitmap loads (no row jump when it arrives).
//  - downsampleImageData / displayTargetPixels: decode at display resolution.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - Media Extension Sets

let nativeImageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg"]
let nativeVideoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
let nativeAudioExts: Set<String> = ["mp3", "m4a", "wav", "aac", "ogg", "flac"]

// MARK: - Media Image Cache

final class NativeMediaImageCache {
    static let shared = NativeMediaImageCache()
    private let cache = NSCache<NSString, UIImage>()
    /// Persistent record of image pixel sizes, keyed by canonical source URL.
    /// Used by `ImageAttachment.attachmentBounds` to compute the correct
    /// attachment height *before* the bitmap is loaded, so the cell self-sizes
    /// to the final layout on the very first pass — instead of locking at the
    /// 200pt placeholder, then losing the trailing markdown text below the
    /// image to clipsToBounds when the late `invalidateCellSizeIfNeeded` grow
    /// is rejected by SwiftUI's UIHostingConfiguration cache.
    ///
    /// Backed by UserDefaults so cold starts (the symptom case: app killed →
    /// re-entered conversation, or message-list session re-load from disk)
    /// already have the size on the very first attachmentBounds call.
    /// [AttachHang preload-bounds]
    private static let defaultsKey = "MinisImageSizes_v1"
    private var sizes: [String: CGSize]
    private let sizesLock = NSLock()
    private init() {
        cache.countLimit = 50
        // Hydrate from UserDefaults. Stored as ["src": "wxh"] (string-encoded
        // so the dictionary serialises cleanly through plist encoding).
        var loaded: [String: CGSize] = [:]
        if let raw = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] {
            for (k, v) in raw {
                let parts = v.split(separator: "x")
                if parts.count == 2,
                   let w = Double(parts[0]),
                   let h = Double(parts[1]) {
                    loaded[k] = CGSize(width: w, height: h)
                }
            }
        }
        self.sizes = loaded
    }

    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func set(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }

    // MARK: - [T-ios-failed-image-refetch-storm] Negative (failure) cache
    //
    // A broken HTTP(S) image URL has no per-instance retry budget across cell
    // reuse: scrolling recycles the cell, CACHE-WIPE recreates the
    // ImageAttachment with retriesRemaining reset, so the SAME failing URL
    // re-fetches on every recycle. Each failed fetch fires onLoad → updateAttachment
    // Views → re-render → re-fetch, a main-thread storm that shows up as the
    // residual scroll-deceleration jank on image-heavy sessions (device log:
    // 28 MinisImage + 19 AttachHotPath events on a single 115ms landing frame,
    // all the same FAILED url). Record failures process-wide with a short TTL
    // so a recycled cell doesn't re-hit the network; the TTL lets a transient
    // network error recover later (a fresh attempt after the window).
    private var failedSources: [String: CFAbsoluteTime] = [:]
    private let failedLock = NSLock()
    /// How long a failed source stays suppressed before a retry is allowed.
    private let failureTTL: CFAbsoluteTime = 60

    /// True if `src` failed to load within the last `failureTTL` seconds.
    func isRecentlyFailed(_ src: String) -> Bool {
        failedLock.lock(); defer { failedLock.unlock() }
        guard let t = failedSources[src] else { return false }
        if CFAbsoluteTimeGetCurrent() - t > failureTTL {
            failedSources.removeValue(forKey: src)  // expired — allow a fresh attempt
            return false
        }
        return true
    }

    /// Record that `src` failed to produce an image (negative-cache it).
    func recordFailure(_ src: String) {
        failedLock.lock(); failedSources[src] = CFAbsoluteTimeGetCurrent(); failedLock.unlock()
    }

    /// Clear a source's failure record (call on a successful load so a URL that
    /// recovered isn't suppressed by a stale entry).
    func clearFailure(_ src: String) {
        failedLock.lock(); failedSources.removeValue(forKey: src); failedLock.unlock()
    }

    /// Lookup the recorded pixel size for a source URL (canonical form, no
    /// fingerprint suffix). Returns nil if we've never loaded this URL.
    func size(forSource src: String) -> CGSize? {
        sizesLock.lock(); defer { sizesLock.unlock() }
        return sizes[src]
    }
    /// Record a source URL → pixel-size mapping. Call once after a successful
    /// image decode. Persists to UserDefaults so cold starts can use it.
    func recordSize(_ size: CGSize, forSource src: String) {
        sizesLock.lock()
        if sizes[src] == size {
            sizesLock.unlock()
            return
        }
        sizes[src] = size
        let snapshot = sizes
        sizesLock.unlock()
        // Encode and persist outside the lock (UserDefaults can be slow).
        let encoded: [String: String] = snapshot.mapValues { "\($0.width)x\($0.height)" }
        UserDefaults.standard.set(encoded, forKey: Self.defaultsKey)
    }
}

// MARK: - Downsample Helper

/// Downsample image data. maxPixelSize controls the longest edge in pixels.
func downsampleImageData(_ data: Data, maxPixelSize: CGFloat = 2048) -> UIImage? {
    let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else { return nil }
    let downsampleOpts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOpts as CFDictionary) else {
        return UIImage(data: data)
    }
    return UIImage(cgImage: cg)
}

/// [T-ios-image-single-writer] The `maxPixelSize` for decoding a chat-transcript
/// image at DISPLAY size, computed from the header dimensions in `data`.
///
/// Chat images render at ≤ `ImageAttachment.maxImageWidth` points wide, so the
/// sharpest bitmap the screen can ever show is `maxWidth × screenScale` pixels
/// wide. Decoding straight to that target replaces the old two-stage pipeline
/// (decode at a generic 2048 cap, then re-decode from disk at ~2× display width
/// from inside `attachmentBounds`) whose second stage was both a memory
/// double-spend and the placeholder-stuck race described at that call site.
///
/// `CGImageSourceThumbnailMaxPixelSize` caps the LONGEST side, so a tall
/// portrait image capped naively at the width target would come out soft: for
/// aspect > 1 the cap is scaled up so the WIDTH still lands on the target,
/// bounded by the old 2048 ceiling so a pathological strip image cannot blow
/// the decode budget. Wide images cap at the width target directly — strictly
/// less memory than the old 2048 first stage, and at 3× scale strictly sharper
/// than the old second stage (which targeted 2× display width).
///
/// `screenScale` is passed in (not read from UIScreen here) so callers off the
/// main thread stay warning-free; capture it before detaching.
func displayTargetPixels(for data: Data, screenScale: CGFloat) -> CGFloat {
    let widthTargetPx = 400.0 * max(screenScale, 1)   // ImageAttachment.maxImageWidth
    let hardCap: CGFloat = 2048
    let opts = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let src = CGImageSourceCreateWithData(data as CFData, opts),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any],
          let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
          w > 0, h > 0 else {
        // Unreadable header — fall back to the historical generic cap.
        return hardCap
    }
    // EXIF orientations 5-8 swap displayed axes; use the displayed width.
    var dispW = w, dispH = h
    if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value, (5...8).contains(o) {
        swap(&dispW, &dispH)
    }
    let aspect = dispH / dispW
    let longestForSharpWidth = aspect > 1 ? widthTargetPx * aspect : widthTargetPx
    return min(longestForSharpWidth, hardCap)
}
