//
//  MessageListV3HeightCache.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Height cache value types: HeightCacheKey (markdown source + width + font
//  size) and HeightLRU, used by +HeightMeasurement and the Coordinator's
//  attrStringHeightCache.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

// MARK: - Height cache [T-ios-listsessions-perf]

/// Cache key for a measured text-block height.
///
/// Built from the MARKDOWN SOURCE (`block.content`), not the rendered
/// `NSAttributedString.string`. That distinction is load-bearing: the rendered
/// plain text has the markup stripped, so `**bold**` and `bold` produce the
/// same string of the same length while carrying different attribute runs and
/// therefore measuring to different heights at the same width. Keying on the
/// rendered string would hand back a height for the wrong content, which is
/// exactly the stale-height-gap failure this file has been burned by before
/// (see [ios_stale_height_gap_family], [ios_render_collapse_cell_undersized]).
/// The attributed string is a deterministic function of the source plus the
/// font size, so the source is both the safer key and the cheaper one.
///
/// `width` and `fontSize` are part of the key rather than reasons to clear:
/// the LRU deliberately survives session change, so it also survives rotation
/// and a Dynamic Type change, and both must MISS rather than serve a stale
/// height. Font size in particular is not optional — the identity-keyed cache
/// was only ever safe across a font change because `reconfigureAllCells()`
/// wiped it.
///
/// Length is kept alongside the hash for the same reason
/// `userBubbleHeightCache`'s key does: it makes an accidental hash collision
/// between two different bodies vanishingly unlikely without storing the text.
struct HeightCacheKey: Hashable {
    let contentLength: Int
    let contentHash: Int
    let width: Int
    let fontSize: Int

    init(content: String, width: CGFloat, fontSize: CGFloat) {
        self.contentLength = content.count
        self.contentHash = content.hashValue
        // 0.01 pt precision, NOT Int truncation. A wrap decision can turn on
        // a fraction of a point (@3x widths are thirds; the font-scale steps
        // land on .49/.51), and two widths that merely round to the same
        // integer must MISS rather than share a height. A distinct key only
        // costs one re-measure; a shared key can seed a wrong height, which is
        // the stale-height-gap failure again.
        self.width = Int((width * 100).rounded())
        self.fontSize = Int((fontSize * 100).rounded())
    }
}

/// Small insertion-ordered LRU for measured heights.
///
/// Capacity-bounded because it outlives session change: without a cap a
/// long-running app accumulates an entry per distinct (block, width, font)
/// ever measured. 300 entries covers several screens of several sessions,
/// which is the reuse window that matters (reopening a session you were just
/// in), while staying far too small to matter for memory — each entry is two
/// Ints, a Double and a key.
struct HeightLRU {
    private var storage: [HeightCacheKey: CGFloat] = [:]
    /// Keys oldest-first. Only touched on insert and eviction, not on read:
    /// making reads reorder would turn every cache hit into an O(n) array
    /// removal on the main thread, which is the opposite of the point.
    /// Insertion order is therefore the eviction order — a bounded FIFO. For
    /// this access pattern (a snapshot pass sweeping a page of blocks) that is
    /// equivalent to true LRU and costs nothing.
    private var order: [HeightCacheKey] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
        order.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }

    subscript(key: HeightCacheKey) -> CGFloat? {
        get { storage[key] }
        set {
            guard let newValue else {
                if storage.removeValue(forKey: key) != nil {
                    order.removeAll { $0 == key }
                }
                return
            }
            if storage.updateValue(newValue, forKey: key) == nil {
                order.append(key)
                // Evict oldest until back under the cap.
                while order.count > capacity {
                    let oldest = order.removeFirst()
                    storage.removeValue(forKey: oldest)
                }
            }
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}
