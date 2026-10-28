//
//  SessionLoadingCard.swift
//  Minis - chat page (AIChatView)
//
//  LoadingDotsView (the three-dot loading indicator used across the session
//  entry path) and SessionLoadingCard (shown while a session's messages load).
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

// MARK: - Session Loading Card

/// Three-dot carousel indicator: dots pulse in a staggered wave. The single
/// loading language for the session-entry path (loading card, in-place reload,
/// kernel boot) — replaces every system ProgressView spinner there, so the
/// old system spinner never appears after / alongside the new loading UI.
struct LoadingDotsView: View {
    var dotSize: CGFloat = 10
    var color: Color = .accentColor
    @State private var animating = false

    var body: some View {
        HStack(spacing: dotSize * 0.7) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(animating ? 1.0 : 0.55)
                    .opacity(animating ? 0.95 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.16),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

/// Loading placeholder shown while ENTERING a session whose messages haven't
/// loaded yet — replaces the bare system spinner for that first-open moment
/// (black screen → lone spinner → content snap). Just the bare three-dot
/// carousel, centered — no card container or label (visual-simplification
/// feedback: the rounded material box + "Loading conversation…" text read as
/// too heavy). The container's transition fades/scales it out when loading
/// completes. Reload paths with content on screen never show this — see the
/// isLoadingSession overlay in AIChatView.
struct SessionLoadingCard: View {
    var body: some View {
        LoadingDotsView(dotSize: 8)
            .frame(height: 24)
    }
}
