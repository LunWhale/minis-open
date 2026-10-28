//
//  NavBarModifiers.swift
//  Minis - chat page (AIChatView)
//
//  Navigation bar modifiers: NavTitleFrameModifier (also used by
//  HelperTranscriptPage) and NavBarStyleModifier (bar appearance and the top
//  safe-area inset the page reads).
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

// MARK: - Nav Bar Modifiers

// [T-agent-transcript-navbar] Shared with HelperTranscriptPage; logic unchanged.
struct NavTitleFrameModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // [NavTitleTopClip 2026-07-23] The principal titleView aligns to the
            // liquid-glass navbar's ~44pt band. Give it 46pt centered so tall
            // title glyphs (semibold 16pt + CJK/caps ascenders) render in full.
            //
            // [NavTitleTransitionClip 2026-07-23] Do NOT `.clipped()`. During a
            // push/pop transition the system interpolates the principal item's
            // frame/scale/alpha; a hard clip rectangle cuts the mid-transition
            // frames along the 46pt box far more aggressively than the steady
            // state (users saw the title sliced to half a line during the
            // animation). The 46pt frame only *sizes* the item for band
            // alignment — the 3-row stack's natural height already fits within
            // it at steady state (spacing -2, ~44pt), so there is nothing to clip
            // away, and letting transition frames render uncropped restores the
            // standard system title transition.
            content
                .frame(height: 46, alignment: .center)
        } else {
            content
        }
    }
}

// [T-agent-transcript-navbar] Shared with HelperTranscriptPage; logic unchanged.
struct NavBarStyleModifier: ViewModifier {
    @Binding var topSafeAreaInset: CGFloat

    /// [T-agent-transcript-navbar-lost] When false, the iOS 16-18 branch skips
    /// the safe-area measuring overlay entirely.
    ///
    /// That overlay writes `topSafeAreaInset` from an `onGeometryChange`
    /// action. A tool sheet presented from OUTSIDE the page's NavigationStack
    /// (SheetOverlayView, a child VC of the message list) changes the top inset
    /// as it presents and dismisses, so the action fires DURING the dismissal's
    /// view-graph update. On the agent transcript page that update ends with
    /// SwiftUI calling `setNavigationBarHidden(true, animated: false)` -- an
    /// all-SwiftUI call stack, no app frames, once per dismissal,
    /// deterministically -- and the bar never comes back.
    ///
    /// `topSafeAreaInset` has no readers on either page: the one site that
    /// would use it deliberately prefers a constant (see slashPickerTopReserve),
    /// so on the transcript page the overlay is pure cost. The main chat keeps
    /// it (default true) rather than change behaviour that is not implicated.
    var measuresSafeArea: Bool = true

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // iOS 26: extend content behind nav bar so liquid-glass has
            // something to show through; the collection view's
            // contentInsetAdjustmentBehavior = .automatic keeps messages
            // starting below the bar.
            content
                .ignoresSafeArea(.container, edges: .top)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                // [T-macos27-liquid-glass-navbar] See MacOS27GlassWorkaround in
                // ContentView. `toolbarBackgroundVisibility(.visible)` only
                // declares "there should be a backdrop"; the material is still
                // produced by glass sampling — which does not render in a
                // foreground window on macOS 27, leaving the bar fully
                // transparent. Pin an opaque colour here instead (the same one
                // the iOS 16–18 branch below uses). The message list is a
                // UIKit-hosted UICollectionView, so the modifier's
                // scrollEdgeEffectHidden is a no-op for it; what does the work
                // here is toolbarBackground. No change needed in
                // MessageListViewController.
                .modifier(MacOS27OpaqueNavigationBar(background: ChatColors.background))
        } else {
            // iOS 16–18: opaque navbar background
            content
                .toolbarBackground(ChatColors.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .overlay(alignment: .top) {
                    if measuresSafeArea {
                        // [T-ios-geometry-observer-crash] onGeometryChange
                        // replaces the GeometryReader scaffold (async-renderer
                        // SIGTRAP — see the floating-bar site). The proxy
                        // measures the same Color.clear the reader wrapped;
                        // ignoresSafeArea/frame stay outside it exactly as
                        // before, and the action's initial fire covers the old
                        // onAppear seed.
                        Color.clear
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.safeAreaInsets.top
                            } action: { topSafeAreaInset = $0 }
                            .ignoresSafeArea()
                            .frame(height: 0)
                    }
                }
        }
    }
}
