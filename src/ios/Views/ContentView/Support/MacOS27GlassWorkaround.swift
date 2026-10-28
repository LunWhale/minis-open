//
//  MacOS27GlassWorkaround.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  macOS 27 (iOS app on Mac) navigation bar workaround. Shipping code - used
//  by the session list and AIChatView - so it must stay outside `#if DEBUG`.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

// [T-macos27-liquid-glass-navbar] NOTE: everything from here to the matching
// `#if DEBUG` below is SHIPPING code and must stay OUTSIDE that block. It was
// originally added inside the temporary SessionRow height probe's `#if DEBUG`,
// which compiled `MacOS27GlassWorkaround` and `MacOS27OpaqueNavigationBar` out
// of Release while their two call sites (ContentView.swift and
// AIChatView.swift) stayed unconditional -- Debug built fine and only the
// Release archive failed with "cannot find 'MacOS27OpaqueNavigationBar' in
// scope". Do not merge these blocks back together.
/// [T-macos27-liquid-glass-navbar] Two regressions in the iOS 26-style
/// navigation bar on macOS 27 (iOS app on Mac).
///
/// An iOS 26+ navigation bar draws no background of its own; the backdrop comes
/// from the top scroll edge effect of the scroll view beneath it (liquid glass
/// sampled by a CABackdropLayer). On macOS 27 that chain breaks in two places.
/// macOS 26 and every iOS version are fine (verified under LLDB, view trees
/// compared line by line):
///
/// 1. Sidebar (`.plain` List with sticky date headers): the edge effect's
///    height runs away — it measures 416x883 while the list sits at the top
///    (contentOffset=-74), where 75 is correct. Scrolling up re-pins a header
///    and triggers it, and it never recovers, so a broad band of rows at the
///    top of the sidebar renders blurred. Controls: the detail column (no
///    sections) is a steady 997x75; switching to `.listStyle(.sidebar)` (which
///    does not pin headers on Mac) returns it to 416x75.
///    `.scrollEdgeEffectHidden(top)` removes the blur — but then the bar has no
///    backdrop at all.
/// 2. Detail column: the effect is sized correctly (75), yet while the window
///    is in the FOREGROUND the glass does not render at all — the bar is fully
///    transparent and body text shows through the title. It looks right once
///    the window loses focus. The foreground and background view trees are
///    identical line by line (hidden, alpha, z-order included); the difference
///    is one layer down, in the compositor — backdrop sampling fails in an
///    active window.
///
/// Conclusion: on this system the bar's backdrop cannot rely on the edge effect
/// / backdrop path. The workaround is to switch the top edge effect off and give
/// the bar an explicit background. The List style is untouched, so the sticky
/// date headers stay.
///
/// Already ruled out, do not retry: `.scrollEdgeEffectStyle(.hard)` (the style
/// applies but the height is unchanged, and it does not cover sticky headers —
/// same report in Apple forums thread/795159); an opaque `.background` plus
/// `.scrollContentBackground(.hidden)` (the list background is not what is
/// sampled); mutating the effect view's hidden/alpha/frame at runtime (the
/// system rebuilds and restores it on every layout, so the experiment shows
/// nothing).
///
/// Once Apple fixes this: delete this enum, `MacOS27OpaqueNavigationBar` and the
/// two `.modifier(...)` call sites.
enum MacOS27GlassWorkaround {
    /// Scope: running on a Mac, on system 27.
    ///
    /// This app runs on the Mac as "Designed for iPad" (the iOS binary run
    /// as-is, `Wrapper/Minis.app`, `LSRequiresIPhoneOS=true`) — it is NOT a Mac
    /// Catalyst build, so `#if targetEnvironment(macCatalyst)` is always false
    /// here and gating on it compiles the whole workaround out as dead code
    /// (already tried once). The only reliable test is the runtime
    /// `isiOSAppOnMac`; the Catalyst branch is kept as well so this still holds
    /// if the build form ever changes.
    ///
    /// System version: for iOS-on-Mac, `UIDevice.systemVersion` reports the HOST
    /// macOS major version (measured: 27.0), so `#available(iOS 27.0, *)`
    /// excludes macOS 26 exactly as intended.
    static let isActive: Bool = {
        guard #available(iOS 27.0, *) else { return false }
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }()
}

/// See MacOS27GlassWorkaround. The choice of `background` matters:
/// - The detail column MUST use an opaque colour (`ChatColors.background`) —
///   its backdrop does not render in an active window, so any Material would
///   fail the same way.
/// - The sidebar uses `Material.bar`: the sidebar column's backdrop DOES render
///   in the foreground (the runaway blur is itself the proof), and the material
///   blends with the Mac sidebar's system grey without leaving a colour seam.
struct MacOS27OpaqueNavigationBar<S: ShapeStyle>: ViewModifier {
    let background: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), MacOS27GlassWorkaround.isActive {
            content
                .scrollEdgeEffectHidden(true, for: .top)
                .toolbarBackground(background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            content
        }
    }
}
