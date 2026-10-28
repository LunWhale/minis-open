//
//  MessageListV3Coordinator+DecelDisplayLink.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  DEBUG-only CADisplayLink meter that counts real dropped frames during a
//  deceleration (start/stop/summary are called from +ScrollViewDelegate).
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +DecelDisplayLink" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - [DecelDisplayLink] CADisplayLink frame meter (DEBUG only)
        //
        // The existing `[ScrollDecel] SLOW-FRAME` log measures the wall-clock gap
        // between consecutive `scrollViewDidScroll` callbacks. That is NOT the
        // same as a real dropped frame: during the tail of a decel UIKit stops
        // calling scrollViewDidScroll for the frames where contentOffset doesn't
        // visually change (snap-to-target), so a 250ms "gap" can happen with the
        // main thread completely idle and CADisplayLink ticking 16.7ms steady —
        // a false positive for jank. Run a CADisplayLink only during the decel
        // and measure actual frame intervals; >1.5× the expected vsync interval
        // is a real dropped frame.
        #if DEBUG   // [split] same #if as MessageListV3Coordinator.swift
        @objc private func decelDisplayLinkTick(_ link: CADisplayLink) {
            // The first tick has no prior timestamp — establish the baseline + expected interval.
            if decelDLLastTimestamp == 0 {
                decelDLLastTimestamp = link.timestamp
                decelDLExpectedMs = (link.targetTimestamp - link.timestamp) * 1000
                return
            }
            let gapMs = (link.timestamp - decelDLLastTimestamp) * 1000
            decelDLLastTimestamp = link.timestamp
            decelDLFrames += 1
            if gapMs < decelDLMinGapMs { decelDLMinGapMs = gapMs }
            if gapMs > decelDLMaxGapMs { decelDLMaxGapMs = gapMs }
            // A real dropped frame: gap exceeds 1.5× the expected vsync interval.
            // At 120Hz expected≈8.33ms → threshold≈12.5ms; at 60Hz ≈16.67ms → 25ms.
            let dropThreshold = decelDLExpectedMs * 1.5
            if gapMs > dropThreshold {
                decelDLDrops += 1
                let cv = viewController?.collectionView
                let off = cv?.contentOffset.y ?? 0
                let sinceStart = (CACurrentMediaTime() - decelStartTime) * 1000
                let dropped = Int((gapMs / decelDLExpectedMs).rounded()) - 1
                AppLogger(category: "ScrollDecel").warning("[DecelDisplayLink][DROP] +\(String(format: "%.0f", sinceStart))ms into decel gap=\(String(format: "%.1f", gapMs))ms (expected \(String(format: "%.1f", self.decelDLExpectedMs))ms, ~\(dropped) frame(s) dropped) offset=\(String(format: "%.0f", off)) remainToTarget=\(String(format: "%.0f", self.decelTargetOffset - off)) frame#\(self.decelDLFrames)")
            }
        }

        func startDecelDisplayLink() {
            stopDecelDisplayLink()
            decelDLLastTimestamp = 0
            decelDLFrames = 0
            decelDLDrops = 0
            decelDLMinGapMs = .infinity
            decelDLMaxGapMs = 0
            let link = CADisplayLink(target: self, selector: #selector(decelDisplayLinkTick(_:)))
            link.add(to: .main, forMode: .common)
            decelDisplayLink = link
        }

        func stopDecelDisplayLink() {
            decelDisplayLink?.invalidate()
            decelDisplayLink = nil
        }

        func logDecelDisplayLinkSummary() {
            guard decelDLFrames > 0 else { return }
            let dur = (CACurrentMediaTime() - decelStartTime) * 1000
            let actualFps = decelDLFrames > 0 ? Double(decelDLFrames) / (dur / 1000) : 0
            let minGap = decelDLMinGapMs.isFinite ? decelDLMinGapMs : 0
            AppLogger(category: "ScrollDecel").info("[DecelDisplayLink][SUMMARY] dur=\(String(format: "%.0f", dur))ms frames=\(self.decelDLFrames) drops=\(self.decelDLDrops) actualFps=\(String(format: "%.1f", actualFps)) gapRange=[\(String(format: "%.1f", minGap))..\(String(format: "%.1f", self.decelDLMaxGapMs))]ms expected=\(String(format: "%.1f", self.decelDLExpectedMs))ms")
        }
        #endif
}
