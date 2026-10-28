//
//  ComposerSurface.swift
//  Minis - chat page (AIChatView)
//
//  Surfaces of the composer and the floating buttons: FloatingCircleButtonSurface
//  (scroll / download buttons, also used by BrowserSheetView), ComposerSurface
//  (the composer's rounded container) and ComposerContextGlow (context-usage
//  glow). The "Swipe-to-Send Hint" note at the end documents SwipeToSendHint,
//  which lives in ChatInputBar.swift.
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

// MARK: - Composer Surface

/// Circular surface for the small floating buttons over the message list
/// (scroll up / down, browser downloads).
///
/// iOS 26+: interactive Liquid Glass circle, matching the glass nav-bar
/// buttons. No hand-rolled stroke or shadow — the material draws its own edge
/// and lift, and stacking the old ones reads as a dark halo (FAB finding).
/// `contentShape(Circle())` is required: `.glassEffect` draws a material but
/// contributes no hit-testable shape, so without it only the glyph's pixels
/// would take taps (see [T-fab-glass-contextmenu-regression]).
///
/// Below iOS 26 the original disc is kept byte-for-byte. The light-mode
/// defaults are the [T-ios-scrollbtn-invisible-lightmode] values: a
/// half-transparent white disc was invisible over plain reply text, so the
/// fill is near-opaque with a readable border and shadow. Callers with their
/// own historical values pass them in.
struct FloatingCircleButtonSurface: ViewModifier {
    var legacyLightOpacity: Double = 0.92
    var legacyStrokeOpacity: Double = 0.35
    var legacyShadowOpacity: Double = 0.18
    var legacyShadowRadius: CGFloat = 5

    @Environment(\.colorScheme) private var colorScheme

    /// Glyph style for icons on this surface. Inside a default-styled Button
    /// both resolve against the button tint (accent): `.secondary` is a faded
    /// accent that washes out against the glass material, `.primary` is the
    /// full-strength accent, which stays readable (verified on device).
    /// Sub-26 keeps the original `.secondary` over its opaque disc.
    static var glyphStyle: HierarchicalShapeStyle {
        if #available(iOS 26.0, *) { return .primary }
        return .secondary
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        } else {
            content
                .background {
                    Color(.systemBackground)
                        .opacity(colorScheme == .dark ? 0.8 : legacyLightOpacity)
                        .clipShape(Circle())
                }
                .overlay(Circle().stroke(Color.gray.opacity(legacyStrokeOpacity), lineWidth: 0.5))
                .shadow(color: .black.opacity(legacyShadowOpacity), radius: legacyShadowRadius, y: 2)
        }
    }
}

/// Background + shadow for the composer's outer rounded container.
///
/// **[T-popup-white-patch 7a0e3d62] — the invariant both branches must keep.**
/// The fill is painted INSIDE a rounded shape, never as a rectangular
/// `.background(color)` + `.clipShape(...)` pair. With that older pairing the
/// host CALayer carried a rectangular backing colour which the system
/// text-selection / edit-menu pop animation snapshotted *before* SwiftUI's mask
/// applied, flashing a square of colour around the rounded corners mid-animation.
/// Filling the shape directly leaves the host layer's `backgroundColor` at
/// `.clear`, so the snapshot is already rounded. `clipShape` is still applied so
/// child views (text view, attachment grid) are clipped to the same rect.
///
/// `glassEffect(in:)` composites the material into the shape it is given, for
/// the same reason: it does not set a rectangular layer background, so it
/// preserves the invariant rather than reintroducing the bug. Verified on device
/// by long-pressing composer text to raise the edit menu — see the task notes.
///
/// The two hand-rolled shadows are dropped on the glass path (Liquid Glass
/// renders its own edge and shadow; stacking the old ones reads as a dark halo —
/// the same finding as the FAB conversion). The sub-26 branch keeps the original
/// fill and BOTH shadows byte-for-byte, including the dark-mode-only top shadow
/// that lifts the bar off the message list.
struct ComposerSurface: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .clipShape(shape)
        } else {
            content
                .background(shape.fill(ChatColors.inputBg))
                .clipShape(shape)
                .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 2)
                .shadow(color: Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.5) : UIColor(white: 0, alpha: 0) }), radius: 8, x: 0, y: -4)
        }
    }
}

/// [T-ios-context-usage-hint] Inner glow along the composer's own wall when the
/// context window is filling up: amber from 70%, red from 80%.
///
/// One layer, clipped by the composer's shape so nothing escapes the outline
/// (the acceptance criterion from the on-device review): a 13 pt stroke
/// blurred 7 pt. Half of it and its blur spill lie outside the wall; the clip
/// discards them, so only a soft inward fade survives. There is deliberately
/// NO crisp outline stroke any more — the 00462a9d build had one and the user
/// read the ring as a heavy border; the light should feel like it is in the
/// wall, not drawn on it.
///
/// Blending is what the previous version got wrong. `.screen` over a
/// near-white light-mode surface has almost no colouring power — the
/// 87188e3b build was invisible in light mode, within ~2 RGB steps of the
/// background. So light mode now uses `.normal` (real tint on the pale
/// wall) at a visibly higher opacity; dark mode keeps `.plusLighter`, which
/// adds light and never darkens the material. Warning is amber
/// (systemOrange) rather than systemYellow, which washes out on light
/// surfaces.
///
/// Only opacity ever animates (critical-tier breathing, compositor-side; off
/// under Reduce Motion). No `drawingGroup`, no per-frame re-blur.
/// `allowsHitTesting(false)`; the view's frame equals the composer's, so the
/// contentShape, tap target and geometry observers are untouched. Mounted as
/// an `.overlay` above the material so the Liquid Glass backdrop sampler
/// never sees it.
struct ComposerContextGlow: View {
    let tier: ContextUsage.Tier
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    /// Must match ComposerSurface's shape exactly: it is the stroke path and
    /// the clip that keeps the glow inside the wall.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }
    private var color: Color {
        tier == .critical ? Color(UIColor.systemRed) : Color(UIColor.systemOrange)
    }
    /// Overall visibility of the glow. Light mode needs more: a normal-blend
    /// tint on a pale wall reads weaker than additive light on a dark one.
    /// Brought down ~30% from 00462a9d ("looks a bit heavy").
    private var baseOpacity: Double {
        let dark = colorScheme == .dark
        switch tier {
        case .normal: return 0
        case .warning: return dark ? 0.20 : 0.26
        // Critical sits only a step above warning on purpose: on device the
        // 0.26 / 0.34 red still read as heavy ("a little lighter").
        case .critical: return dark ? 0.16 : 0.22
        }
    }

    var body: some View {
        ZStack {
            // Inserted/removed rather than held at opacity 0: an invisible
            // blurred layer would still be composited whenever the composer
            // re-renders.
            if tier != .normal {
                // Diffuse inner glow only: soft falloff from the wall inward.
                shape
                    .stroke(color, lineWidth: 13)
                    .blur(radius: 7)
                    // The clip is what makes this an INNER glow: the stroke's
                    // outer half and the blur spill are discarded.
                    .clipShape(shape)
                .blendMode(colorScheme == .dark ? .plusLighter : .normal)
                .opacity(breathing ? baseOpacity * 0.6 : baseOpacity)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.35), value: tier)
        .onAppear { updateBreathing() }
        .onChange(of: tier) { _ in updateBreathing() }
        .onChange(of: reduceMotion) { _ in updateBreathing() }
    }

    private func updateBreathing() {
        if tier == .critical && !reduceMotion {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                breathing = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { breathing = false }
        }
    }
}

// MARK: - Swipe-to-Send Hint

/// Floating "send arrow + Release to send" hint shown while the user is
/// dragging the input bar upward. Extracted out of `inputBar` because
/// inlining `.overlay { HStack { … } .offset(…).animation(…) }` deepens
/// SwiftUI's already-fragile generic chain on `inputBar.body` and crashes
/// the runtime type-metadata decoder via deep recursion
/// (`swift_getTypeByMangledName...`). Keeping the overlay as a single named
/// struct lets the parent's generic signature collapse to one slot.
///
/// - `progress` 0...1: drag distance as a fraction of the send threshold.
///   Arrow opacity = `min(1, progress * 1.4)`. Capsule opacity ramps in
///   over `[0.4, 0.8]` so it reaches full opacity exactly at the arming
///   fraction (`kSendSwipeArmFraction = 0.8`), where the haptic tick
///   fires and lifting the finger sends.
/// - `armFraction`: the threshold at which release fires send. Drives the
///   spring "pop" animation so the visual confirmation matches behavior.
/// - `location`: live fingertip position in the input bar's coordinate
///   space. The hint sits ~60pt above the finger (about one thumb-tip).
