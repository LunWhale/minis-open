//
//  ChatToolbarHost.swift
//  Minis - chat page (AIChatView)
//
//  The chat page's toolbar, kept stable while a reply streams: the DEBUG
//  NavbarEvalStats counters, EquatableByValue, the NavTitleKey /
//  ChatToolbarKey display keys, ChatToolbarHost (hosts the whole toolbar behind
//  an equatable gate), ChatTrailingMenu (the native "..." menu) and
//  ChatTrailingMenuButton (the UIKit menu) and ChatNavMenuBarItemInstaller
//  (puts that menu on the navigation item as a real bar button).
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

// MARK: - Chat Trailing "…" Menu

/// [T-ios-trailing-menu-streaming-stability] The chat page's "…" menu,
/// extracted from AIChatView into an Equatable child so an OPEN menu stays
/// stable during streaming. AIChatView.body re-evaluates on every streaming
/// tick (the whole view observes the view model); with the Menu declared
/// inline, each tick pushed rebuilt menu content into the presented UIMenu,
/// which could reshuffle/reset it right as the user tapped — the reported
/// mis-taps on menu items mid-stream.
///
/// `.equatable()` at the call site makes SwiftUI diff with `==` below, which
/// compares ONLY the values that change what the menu displays — none of
/// which mutate during a stream — so streaming ticks stop invalidating this
/// subtree entirely. Action closures are recreated by every parent body pass
/// but never change behavior, so they're deliberately excluded from `==`.
/// [T-ios-navbar-principal-streaming-stability] Generic value-keyed equatable
/// wrapper. SwiftUI skips re-evaluating `content` while `key` compares equal —
/// the same guard ChatTrailingMenu gets from its custom `==`, made reusable
/// for views (like the navbar titleView) that are too entangled with local
/// @State/onChange plumbing to extract wholesale. The content closure is
/// recreated every parent pass but is excluded from equality, exactly like
/// ChatTrailingMenu's action closures. Internal @State / onReceive updates
/// inside `content` still fire on their own — only parent-driven invalidation
/// is gated. Anything the content READS from the parent/vm must therefore be
/// represented in `key`, or its changes will not render.
#if DEBUG
/// [T-ios-navbar-principal-streaming-stability] Eval counters proving (or
/// disproving) that the toolbar equatable gates actually hold during
/// streaming. toolbarPass ≈ one per streaming tick (counted in navTitleKey,
/// which the toolbar builder computes every pass); titleEval / menuEval
/// should stay ~1 while a stream runs IF the gates work. Grep: [NavbarEval].
enum NavbarEvalStats {
    static var toolbarPass = 0
    static var titleEval = 0
    static var menuEval = 0
    static let logger = AppLogger(category: "NavbarEval")
}
#endif

private struct EquatableByValue<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    @ViewBuilder let content: () -> Content

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    @ViewBuilder
    var body: some View {
        #if DEBUG
        let _ = {
            NavbarEvalStats.titleEval += 1
            NavbarEvalStats.logger.info("[NavbarEval] titleEval=\(NavbarEvalStats.titleEval) (toolbarPass=\(NavbarEvalStats.toolbarPass))")
        }()
        #endif
        content()
    }
}

/// [T-ios-navbar-principal-streaming-stability] Every display input the navbar
/// principal titleView renders, snapshotted as an Equatable key. While this is
/// unchanged (the entire streaming case), SwiftUI proves the principal toolbar
/// item unchanged and does NOT re-push the navigation bar's item set — which
/// was what kept rebuilding the OPEN "..." UIMenu each token even after
/// 59b31441 equatable-guarded the trailing menu itself: the guard covered the
/// trailing subtree, but the un-guarded principal item invalidated the whole
/// bar every tick, and UIKit refreshes the presented menu when bar items are
/// re-set (items shifting under the user's finger → mis-taps).
struct NavTitleKey: Equatable {
    let sessionTitle: String?
    let canEditTitle: Bool
    let soulName: String
    let modelName: String
    let isGroupBound: Bool
    /// [T-codex-fast-mode] Bolt badge before the model name while a faster tier
    /// applies. [T-codex-speed-tier] Tier, so Fast and Ultrafast differ.
    let speedBadge: SpeedTier
    let resolvedText: String?
    let hasBinding: Bool
    let hasProviders: Bool
    let showThinkingBadge: Bool
    let thinkingLevelName: String
    let fallbackTrigger: Int
    /// The fallback-pulse @State lives on AIChatView but is RENDERED inside
    /// the gated titleView — each discrete set (6 over ~1.75s) must pierce
    /// the gate or the red pulse freezes at its first frame.
    let fallbackPulse: Double
    /// [T-ios-navtitle-blur-stuck-after-unlock] Face ID lock state — the
    /// title's `.blur(radius: titleIsVisuallyLocked ? 8 : 0)` renders inside
    /// the gated toolbar content, so the unlock transition must pierce the
    /// gate too. Without this field the chat body unblurred on unlock while
    /// the navbar title stayed frozen at blur 8 (user report 2026-07-24).
    let titleLocked: Bool
}

/// [T-ios-navbar-toolbar-host] Combined display key for the WHOLE toolbar:
/// the principal title's inputs plus the trailing menu's eight displayed
/// values. While this is unchanged, ChatToolbarHost.body — and therefore the
/// ToolbarContent builder — never re-runs.
struct ChatToolbarKey: Equatable {
    let navTitle: NavTitleKey
    let messagesEmpty: Bool
    let hasSession: Bool
    let isForcePulling: Bool
    let iCloudSyncEnabled: Bool
    let memoryEnabled: Bool
    let speakEnabled: Bool
    let showEnhancedCacheToggle: Bool
    let enhancedCacheEnabled: Bool
    /// [T-codex-fast-mode] Menu row shown only for Codex OAuth models.
    let showFastModeToggle: Bool
    /// [T-codex-speed-tier] Tier shown (checkmark / subtitle) and whether the
    /// Ultrafast submenu is offered for the active model.
    let speedTier: SpeedTier
    let showUltrafast: Bool
    /// [T-always-on] Without it here the toolbar host never rebuilds and the
    /// menu's checkmark goes stale.
    let keepAwakeEnabled: Bool
    /// [T-always-on-now] Checkmark of the "Use Screen Saver" row.
    let screenSaverNowEnabled: Bool
}

/// [T-ios-navbar-toolbar-host] Zero-footprint host that owns the navigation
/// toolbar. Attached via .background on the chat content, so it sits inside
/// the NavigationStack destination (toolbar registers from any descendant),
/// occupies no layout, and — being Equatable on the toolbar's displayed
/// inputs — its body (the ToolbarContent builder) only re-runs when something
/// the toolbar actually shows changes. Streaming ticks leave the key equal,
/// the builder never re-runs, the bridge gets no new ToolbarContent to push,
/// and the OPEN native SwiftUI Menu stays untouched. Content closures are
/// recreated by every parent pass (excluded from ==, same pattern as
/// EquatableByValue/ChatTrailingMenu) so a key change always renders through
/// the freshest parent state.
struct ChatToolbarHost<Title: View, Trailing: View>: View, Equatable {
    let key: ChatToolbarKey
    /// [T-ios-navbar-menu-baritem] False while ChatNavMenuBarItemInstaller
    /// owns the "..." as a real UIBarButtonItem: the SwiftUI trailing item is
    /// then left out entirely, so the bridge has nothing of ours to push.
    var showsTrailing = true
    @ViewBuilder let title: () -> Title
    @ViewBuilder let trailing: () -> Trailing

    static func == (lhs: Self, rhs: Self) -> Bool {
        let eq = lhs.key == rhs.key && lhs.showsTrailing == rhs.showsTrailing
        #if DEBUG
        if !eq {
            // Name the exact field that broke equality so a false-negative
            // key can be pinned from device logs.
            var diffs: [String] = []
            if lhs.key.navTitle != rhs.key.navTitle {
                let l = lhs.key.navTitle, r = rhs.key.navTitle
                if l.sessionTitle != r.sessionTitle { diffs.append("sessionTitle") }
                if l.canEditTitle != r.canEditTitle { diffs.append("canEditTitle") }
                if l.soulName != r.soulName { diffs.append("soulName") }
                if l.modelName != r.modelName { diffs.append("modelName") }
                if l.isGroupBound != r.isGroupBound { diffs.append("isGroupBound") }
                if l.resolvedText != r.resolvedText { diffs.append("resolvedText") }
                if l.hasBinding != r.hasBinding { diffs.append("hasBinding") }
                if l.hasProviders != r.hasProviders { diffs.append("hasProviders") }
                if l.showThinkingBadge != r.showThinkingBadge { diffs.append("showThinkingBadge") }
                if l.thinkingLevelName != r.thinkingLevelName { diffs.append("thinkingLevelName") }
                if l.fallbackTrigger != r.fallbackTrigger { diffs.append("fallbackTrigger") }
                if l.fallbackPulse != r.fallbackPulse { diffs.append("fallbackPulse") }
                if l.titleLocked != r.titleLocked { diffs.append("titleLocked") }
            }
            if lhs.key.messagesEmpty != rhs.key.messagesEmpty { diffs.append("messagesEmpty") }
            if lhs.key.hasSession != rhs.key.hasSession { diffs.append("hasSession") }
            if lhs.key.isForcePulling != rhs.key.isForcePulling { diffs.append("isForcePulling") }
            if lhs.key.iCloudSyncEnabled != rhs.key.iCloudSyncEnabled { diffs.append("iCloudSyncEnabled") }
            if lhs.key.memoryEnabled != rhs.key.memoryEnabled { diffs.append("memoryEnabled") }
            if lhs.key.speakEnabled != rhs.key.speakEnabled { diffs.append("speakEnabled") }
            if lhs.key.showEnhancedCacheToggle != rhs.key.showEnhancedCacheToggle { diffs.append("showEnhancedCacheToggle") }
            if lhs.key.enhancedCacheEnabled != rhs.key.enhancedCacheEnabled { diffs.append("enhancedCacheEnabled") }
            if lhs.key.showFastModeToggle != rhs.key.showFastModeToggle { diffs.append("showFastModeToggle") }
            if lhs.key.speedTier != rhs.key.speedTier { diffs.append("speedTier") }
            if lhs.key.showUltrafast != rhs.key.showUltrafast { diffs.append("showUltrafast") }
            if lhs.key.keepAwakeEnabled != rhs.key.keepAwakeEnabled { diffs.append("keepAwakeEnabled") }
            if lhs.key.screenSaverNowEnabled != rhs.key.screenSaverNowEnabled { diffs.append("screenSaverNowEnabled") }
            NavbarEvalStats.logger.info("[NavbarEval] host == FALSE diffs=[\(diffs.joined(separator: ","))]")
        }
        #endif
        return eq
    }

    var body: some View {
        #if DEBUG
        let _ = {
            NavbarEvalStats.titleEval += 1
            NavbarEvalStats.logger.info("[NavbarEval] toolbarHostEval=\(NavbarEvalStats.titleEval) (toolbarPass=\(NavbarEvalStats.toolbarPass))")
        }()
        #endif
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .toolbar {
                ToolbarItem(placement: .principal) { title() }
                if showsTrailing {
                    ToolbarItem(placement: .topBarTrailing) { trailing() }
                }
            }
    }
}

/// [T-ios-navbar-uikit-menu] UIKit-owned replacement for ChatTrailingMenu.
///
/// Instrumented device run (NavbarEval, 2026-07-17 19:35): during a streaming
/// reply the toolbar builder ran 34 times while BOTH equatable gates held
/// (titleEval=3, menuEval=2) — yet the presented menu still refreshed. The
/// leak is below SwiftUI: the toolbar bridge re-pushes the navigation item's
/// bar buttons every host pass even when the content views compare equal, and
/// UIKit refreshes/re-anchors a presented UIMenu whenever its bar's items are
/// re-set. No amount of view-level Equatable can stop that.
///
/// Fix: own the button AND the menu in UIKit. The UIViewRepresentable's
/// UIButton instance survives SwiftUI updates, the presented UIMenu is
/// anchored to that stable instance, and updateUIView only touches
/// `button.menu` when the DISPLAYED state actually changed — a no-op SwiftUI
/// pass physically cannot reach the menu. Field names/order are identical to
/// ChatTrailingMenu so the call site only swaps the type name. The DEBUG
/// request-count rows use UIDeferredMenuElement.uncached to stay fresh at
/// each open, matching the SwiftUI Menu's lazy content read.
/// [T-ios-navbar-toolbar-host] Native SwiftUI "..." menu, restored. The
/// UIKit ChatTrailingMenuButton below remains as the proven fallback (it
/// verifiably stops the mid-stream refresh but loses the system's round
/// Liquid-Glass chrome); with the toolbar now hosted in the equatable-gated
/// ChatToolbarHost the ToolbarContent is never rebuilt during streaming, so
/// the native Menu — and its native appearance — should be stable. Item set
/// mirrors the UIKit buildMenu exactly (incl. Compact Messages + the divider
/// between Clear Chat and the iCloud actions from T-chat-menu-compact-entry).
private struct ChatTrailingMenu: View, Equatable {
    let messagesEmpty: Bool
    let hasSession: Bool
    let isForcePulling: Bool
    let iCloudSyncEnabled: Bool
    let memoryEnabled: Bool
    let speakEnabled: Bool
    let showEnhancedCacheToggle: Bool
    let enhancedCacheEnabled: Bool
    /// [T-codex-fast-mode] Mirrors ChatTrailingMenuButton.
    let showFastModeToggle: Bool
    /// [T-codex-speed-tier] Tier shown (checkmark / subtitle) and whether the
    /// Ultrafast submenu is offered for the active model.
    let speedTier: SpeedTier
    let showUltrafast: Bool
    /// [T-always-on] Keep Screen Awake for this chat (the … menu override,
    /// else the global switch): screen on + the Screen Saver if set.
    let keepAwakeEnabled: Bool
    /// [T-always-on-now] "Use Screen Saver" is on for this chat.
    let screenSaverNowEnabled: Bool

    let onNewChat: () -> Void
    let onCompact: () -> Void
    let onClearChat: () -> Void
    let onForceSync: () -> Void
    let onForcePull: () -> Void
    let onOpenTerminal: () -> Void
    let onOpenBrowser: () -> Void
    let onBrowseFiles: () -> Void
    let onSkills: () -> Void
    let onMCPs: () -> Void
    let onMemories: () -> Void
    let setSpeakEnabled: (Bool) -> Void
    let setEnhancedCache: (Bool) -> Void
    let setSpeedTier: (SpeedTier) -> Void
    let setKeepAwake: (Bool) -> Void
    let setScreenSaverNow: (Bool) -> Void
    let onTokenUsage: () -> Void
    let onCopyRequests: () -> Void
    let onCopySessionData: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messagesEmpty == rhs.messagesEmpty
            && lhs.hasSession == rhs.hasSession
            && lhs.isForcePulling == rhs.isForcePulling
            && lhs.iCloudSyncEnabled == rhs.iCloudSyncEnabled
            && lhs.memoryEnabled == rhs.memoryEnabled
            && lhs.speakEnabled == rhs.speakEnabled
            && lhs.showEnhancedCacheToggle == rhs.showEnhancedCacheToggle
            && lhs.enhancedCacheEnabled == rhs.enhancedCacheEnabled
            && lhs.showFastModeToggle == rhs.showFastModeToggle
            && lhs.speedTier == rhs.speedTier
            && lhs.showUltrafast == rhs.showUltrafast
            && lhs.keepAwakeEnabled == rhs.keepAwakeEnabled
            && lhs.screenSaverNowEnabled == rhs.screenSaverNowEnabled
    }

    var body: some View {
        #if DEBUG
        let _ = {
            NavbarEvalStats.menuEval += 1
            NavbarEvalStats.logger.info("[NavbarEval] menuEval=\(NavbarEvalStats.menuEval) (toolbarPass=\(NavbarEvalStats.toolbarPass))")
        }()
        #endif
        return Menu {
            Button { onNewChat() } label: {
                Label(AppLocalized("New Chat"), systemImage: "square.and.pencil")
            }

            Divider()

            // [T-chat-menu-compact-entry] Compact above Clear Chat.
            Button { onCompact() } label: {
                Label(AppLocalized("Compact Messages"), systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .disabled(messagesEmpty)

            Button(role: .destructive) { onClearChat() } label: {
                Label(AppLocalized("Clear Chat"), systemImage: "trash")
            }
            .disabled(messagesEmpty)

            Divider()

            // iCloud sync actions: iOS 17+ (v2 sync engine) AND the user's
            // iCloud Sync toggle on.
            if #available(iOS 17.0, *), iCloudSyncEnabled {
                Button { onForceSync() } label: {
                    Label(AppLocalized("Force iCloud Sync"), systemImage: "icloud.and.arrow.up")
                }
                .disabled(!hasSession || isForcePulling)

                Button { onForcePull() } label: {
                    Label(AppLocalized("Force Pull Messages"), systemImage: "icloud.and.arrow.down")
                }
                .disabled(!hasSession || isForcePulling)

                Divider()
            }

            Button { onOpenTerminal() } label: {
                Label(AppLocalized("Open Terminal"), systemImage: "terminal")
            }

            Button { onOpenBrowser() } label: {
                Label(AppLocalized("Open Browser"), systemImage: "globe")
            }

            Button { onBrowseFiles() } label: {
                Label(AppLocalized("Browse Chat Files"), systemImage: "folder")
            }

            Divider()

            Button { onSkills() } label: {
                Label(AppLocalized("Skills in Session"), systemImage: "puzzlepiece.extension")
            }

            Button { onMCPs() } label: {
                Label(AppLocalized("MCPs in Session"), systemImage: "wrench.and.screwdriver")
            }

            if memoryEnabled {
                Button { onMemories() } label: {
                    Label(AppLocalized("Memories in Session"), systemImage: "brain.head.profile")
                }
            }

            Toggle(isOn: Binding(
                get: { speakEnabled },
                set: { setSpeakEnabled($0) }
            )) {
                Label(AppLocalized("Speak Responses"), systemImage: "speaker.wave.2")
            }

            // [T-keepawake-submenu] One "Keep Screen On" row opening a submenu
            // with both switches (was two top-level rows). Filled icon while
            // either is on. Not on a Mac: no auto-lock, no OLED to protect.
            if !ProcessInfo.processInfo.isiOSAppOnMac {
                Menu {
                    Toggle(isOn: Binding(
                        get: { keepAwakeEnabled },
                        set: { setKeepAwake($0) }
                    )) {
                        Label(AppLocalized("Keep Screen On"), systemImage: "sun.max")
                    }
                    Toggle(isOn: Binding(
                        get: { screenSaverNowEnabled },
                        set: { setScreenSaverNow($0) }
                    )) {
                        Label(AppLocalized("Use Screen Saver"), systemImage: "moon.stars")
                    }
                } label: {
                    Label(AppLocalized("Keep Screen On"),
                          systemImage: keepAwakeEnabled || screenSaverNowEnabled ? "sun.max.fill" : "sun.max")
                }
            }

            // [T-codex-fast-mode-menu-group] Model-control toggles in their
            // own divider-separated section (mirrors the UIKit buildMenu).
            if showEnhancedCacheToggle || showFastModeToggle {
                Divider()

                if showEnhancedCacheToggle {
                    Toggle(isOn: Binding(
                        get: { enhancedCacheEnabled },
                        set: { setEnhancedCache($0) }
                    )) {
                        Label(AppLocalized("Enhanced Cache"), systemImage: "clock.arrow.circlepath")
                    }
                }

                // [T-codex-speed-tier] Only Standard / Fast for this model:
                // the unchanged single switch. With Ultrafast offered: a
                // "Speed" submenu with the three tiers.
                if showFastModeToggle && !showUltrafast {
                    Toggle(isOn: Binding(
                        get: { speedTier != .standard },
                        set: { setSpeedTier($0 ? .fast : .standard) }
                    )) {
                        // [T-codex-speed-icons] Same outline bolt as Fast in
                        // the Speed submenu; the switch itself is unchanged.
                        Label(AppLocalized("Enable Fast Mode"), systemImage: SpeedTier.fast.symbol)
                    }
                } else if showFastModeToggle {
                    Menu {
                        Picker(selection: Binding(
                            get: { speedTier },
                            set: { setSpeedTier($0) }
                        )) {
                            ForEach(SpeedTier.allCases, id: \.self) { tier in
                                Label(tier.title, systemImage: tier.symbol).tag(tier)
                            }
                        } label: { EmptyView() }
                    } label: {
                        Label {
                            // [T-fast-mode-menu-name] Named after the feature
                            // users know ("Fast Mode"), not "Speed".
                            Text(AppLocalized("Fast Mode"))
                            Text(verbatim: speedTier.title)
                        } icon: {
                            Image(systemName: SpeedTier.entrySymbol)
                        }
                    }
                }
            }

            Divider()

            Button { onTokenUsage() } label: {
                Label(AppLocalized("Token Usage"), systemImage: "number")
            }

            #if DEBUG
            Divider()

            Button { onCopyRequests() } label: {
                let n = LastAPIRequestBody.shared.getAll().count
                Label("Copy Requests (\(n))", systemImage: "arrow.up.doc")
            }

            Button { onCopySessionData() } label: {
                Label("Copy Session Data", systemImage: "tray.and.arrow.up")
            }
            #endif
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ChatColors.primaryText)
        }
        // [T-ios-voiceover-labels] Matches the label the UIKit ellipsis button
        // elsewhere in this file already sets, so both read the same.
        .accessibilityLabel(Text("More options", comment: "VoiceOver label for the overflow menu button"))
    }
}

/// [T-ios-navbar-uikit-menu] PROVEN FALLBACK, currently unused: swaps in for
/// ChatTrailingMenu at the trailingMenu call site if the ChatToolbarHost
/// approach ever regresses. Verified on-device (2026-07-17) to stop the
/// mid-stream menu refresh; its remaining flaw was appearance (no native
/// round glass chrome — mitigated here by sizeThatFits reporting the
/// button's intrinsic size so the system container wraps it like a plain
/// toolbar icon).
struct ChatTrailingMenuButton: UIViewRepresentable {
    let messagesEmpty: Bool
    let hasSession: Bool
    let isForcePulling: Bool
    let iCloudSyncEnabled: Bool
    let memoryEnabled: Bool
    let speakEnabled: Bool
    let showEnhancedCacheToggle: Bool
    let enhancedCacheEnabled: Bool
    /// [T-codex-fast-mode] Shown only when the active model's provider is a
    /// Codex OAuth instance (OpenAI OAuth, no custom base).
    let showFastModeToggle: Bool
    /// [T-codex-speed-tier] Tier shown (checkmark / subtitle) and whether the
    /// Ultrafast submenu is offered for the active model.
    let speedTier: SpeedTier
    let showUltrafast: Bool
    /// [T-always-on] Keep Screen Awake for this chat (the … menu override,
    /// else the global switch): screen on + the Screen Saver if set.
    let keepAwakeEnabled: Bool
    /// [T-always-on-now] "Use Screen Saver" is on for this chat.
    let screenSaverNowEnabled: Bool

    let onNewChat: () -> Void
    let onCompact: () -> Void
    let onClearChat: () -> Void
    let onForceSync: () -> Void
    let onForcePull: () -> Void
    let onOpenTerminal: () -> Void
    let onOpenBrowser: () -> Void
    let onBrowseFiles: () -> Void
    let onSkills: () -> Void
    let onMCPs: () -> Void
    let onMemories: () -> Void
    let setSpeakEnabled: (Bool) -> Void
    let setEnhancedCache: (Bool) -> Void
    let setSpeedTier: (SpeedTier) -> Void
    let setKeepAwake: (Bool) -> Void
    let setScreenSaverNow: (Bool) -> Void
    let onTokenUsage: () -> Void
    let onCopyRequests: () -> Void
    let onCopySessionData: () -> Void
    /// [T-multi-select-share] "Share…": pick messages to share as a long image or PDF.
    let onShare: () -> Void
    /// [T-in-chat-search] "Search in Chat": opens the search bar. A static item
    /// - the menu holds no search state, so it never needs rebuilding for it.
    let onSearchInChat: () -> Void

    /// The displayed-state snapshot — the ONLY trigger for a menu rebuild.
    struct Key: Equatable {
        let messagesEmpty: Bool
        let hasSession: Bool
        let isForcePulling: Bool
        let iCloudSyncEnabled: Bool
        let memoryEnabled: Bool
        let speakEnabled: Bool
        let showEnhancedCacheToggle: Bool
        let enhancedCacheEnabled: Bool
        let showFastModeToggle: Bool
        let speedTier: SpeedTier
        let showUltrafast: Bool
        let keepAwakeEnabled: Bool
        let screenSaverNowEnabled: Bool
    }

    fileprivate var key: Key {
        Key(messagesEmpty: messagesEmpty, hasSession: hasSession,
            isForcePulling: isForcePulling, iCloudSyncEnabled: iCloudSyncEnabled,
            memoryEnabled: memoryEnabled, speakEnabled: speakEnabled,
            showEnhancedCacheToggle: showEnhancedCacheToggle,
            enhancedCacheEnabled: enhancedCacheEnabled,
            showFastModeToggle: showFastModeToggle,
            speedTier: speedTier,
            showUltrafast: showUltrafast,
            keepAwakeEnabled: keepAwakeEnabled,
            screenSaverNowEnabled: screenSaverNowEnabled)
    }

    final class Coordinator {
        var lastKey: Key?
        var parent: ChatTrailingMenuButton
        init(parent: ChatTrailingMenuButton) { self.parent = parent }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// [T-chat-statusbar-scrolltotop-mistap] A UIButton whose TOUCH area is
    /// padded out to the 44x44pt HIG minimum while its LAYOUT size stays the
    /// bare icon.
    ///
    /// The two have to differ here. `sizeThatFits` deliberately reports
    /// `intrinsicContentSize` so the toolbar proposes an icon-sized footprint
    /// and wraps the button in the same round glass as any other toolbar icon
    /// — returning anything larger brings back the stretched-capsule
    /// regression of 2026-07-17. But that leaves a genuinely tiny target: the
    /// `ellipsis` glyph at 14pt is a very short symbol, and a `.system` button
    /// built with `setImage` carries no UIButtonConfiguration padding, so the
    /// hittable box is roughly the glyph itself.
    ///
    /// Overriding `point(inside:)` grows only the hit test. Nothing about
    /// layout, the glass chrome, or the menu anchor changes.
    final class HitPaddedButton: UIButton {
        static let minimumTouchSize: CGFloat = 44

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            let dx = min(0, (bounds.width - Self.minimumTouchSize) / 2)
            let dy = min(0, (bounds.height - Self.minimumTouchSize) / 2)
            return bounds.insetBy(dx: dx, dy: dy).contains(point)
        }
    }

    func makeUIView(context: Context) -> UIButton {
        let button = HitPaddedButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.setImage(UIImage(systemName: "ellipsis", withConfiguration: cfg), for: .normal)
        button.tintColor = UIColor(ChatColors.primaryText)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = AppLocalized("More options")
        button.menu = Self.buildMenu(key: key, coordinator: context.coordinator)
        context.coordinator.lastKey = key
        return button
    }

    /// Report the button's intrinsic size so the toolbar proposes an
    /// icon-sized footprint and the system wraps it in the same round glass
    /// as a plain toolbar icon (a representable otherwise accepts the full
    /// proposed width -> stretched capsule, the 2026-07-17 regression).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }

    func updateUIView(_ button: UIButton, context: Context) {
        // Closures capture view state -- refresh them every pass so actions
        // always see the latest values (excluded from the rebuild decision,
        // exactly like ChatTrailingMenu's ==).
        context.coordinator.parent = self
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key
        button.menu = Self.buildMenu(key: key, coordinator: context.coordinator)
        #if DEBUG
        NavbarEvalStats.menuEval += 1
        NavbarEvalStats.logger.info("[NavbarEval] uikitMenuRebuild=\(NavbarEvalStats.menuEval) (toolbarPass=\(NavbarEvalStats.toolbarPass))")
        #endif
    }

    fileprivate static func buildMenu(key: Key, coordinator: Coordinator) -> UIMenu {
        var groups: [UIMenuElement] = []

        groups.append(UIMenu(options: .displayInline, children: [
            UIAction(title: AppLocalized("New Chat"),
                     image: UIImage(systemName: "square.and.pencil")) { _ in coordinator.parent.onNewChat() },
            UIAction(title: AppLocalized("Share Chat…"),
                     image: UIImage(systemName: "square.and.arrow.up"),
                     attributes: key.messagesEmpty ? [.disabled] : []) { _ in coordinator.parent.onShare() },
            UIAction(title: AppLocalized("Search in Chat"),
                     image: UIImage(systemName: "magnifyingglass"),
                     attributes: key.messagesEmpty ? [.disabled] : []) { _ in coordinator.parent.onSearchInChat() },
        ]))

        // [T-chat-menu-compact-entry] Compact sits ABOVE Clear Chat in its own
        // group with the destructive clear; the iCloud actions moved to a
        // separate inline group so a divider lands between Clear Chat and the
        // sync rows (user-requested layout).
        groups.append(UIMenu(options: .displayInline, children: [
            UIAction(title: AppLocalized("Compact Messages"),
                     image: UIImage(systemName: "arrow.down.right.and.arrow.up.left"),
                     attributes: key.messagesEmpty ? [.disabled] : []) { _ in coordinator.parent.onCompact() },
            UIAction(title: AppLocalized("Clear Chat"),
                     image: UIImage(systemName: "trash"),
                     attributes: key.messagesEmpty ? [.destructive, .disabled] : [.destructive]) { _ in coordinator.parent.onClearChat() },
        ]))

        // Same gate as before: iOS 17+ (v2 sync engine) AND the user's
        // iCloud Sync toggle on.
        if #available(iOS 17.0, *), key.iCloudSyncEnabled {
            let disabled: UIMenuElement.Attributes = (!key.hasSession || key.isForcePulling) ? [.disabled] : []
            groups.append(UIMenu(options: .displayInline, children: [
                UIAction(title: AppLocalized("Force iCloud Sync"),
                         image: UIImage(systemName: "icloud.and.arrow.up"),
                         attributes: disabled) { _ in coordinator.parent.onForceSync() },
                UIAction(title: AppLocalized("Force Pull Messages"),
                         image: UIImage(systemName: "icloud.and.arrow.down"),
                         attributes: disabled) { _ in coordinator.parent.onForcePull() },
            ]))
        }

        groups.append(UIMenu(options: .displayInline, children: [
            UIAction(title: AppLocalized("Open Terminal"),
                     image: UIImage(systemName: "terminal")) { _ in coordinator.parent.onOpenTerminal() },
            UIAction(title: AppLocalized("Open Browser"),
                     image: UIImage(systemName: "globe")) { _ in coordinator.parent.onOpenBrowser() },
            UIAction(title: AppLocalized("Browse Chat Files"),
                     image: UIImage(systemName: "folder")) { _ in coordinator.parent.onBrowseFiles() },
        ]))

        var sessionGroup: [UIMenuElement] = [
            UIAction(title: AppLocalized("Skills in Session"),
                     image: UIImage(systemName: "puzzlepiece.extension")) { _ in coordinator.parent.onSkills() },
            UIAction(title: AppLocalized("MCPs in Session"),
                     image: UIImage(systemName: "wrench.and.screwdriver")) { _ in coordinator.parent.onMCPs() },
        ]
        if key.memoryEnabled {
            sessionGroup.append(UIAction(title: AppLocalized("Memories in Session"),
                                         image: UIImage(systemName: "brain.head.profile")) { _ in coordinator.parent.onMemories() })
        }
        sessionGroup.append(UIAction(title: AppLocalized("Speak Responses"),
                                     image: UIImage(systemName: "speaker.wave.2"),
                                     state: key.speakEnabled ? .on : .off) { _ in
            coordinator.parent.setSpeakEnabled(!key.speakEnabled)
        })
        // [T-keepawake-submenu] One "Keep Screen On" row opening a submenu with
        // both switches for this chat (was two top-level rows):
        //   - Keep Screen On  [T-always-on]: the per-chat override (checked = on)
        //   - Use Screen Saver [T-always-on-now]: keep awake + Screen Saver even
        //     if Off in Settings; usable any time, no longer only mid-run.
        // A UIMenu has no checkmark state, so while either is on the row shows
        // a filled icon and an "On" subtitle. Not on a Mac: no auto-lock, no
        // OLED to protect.
        if !ProcessInfo.processInfo.isiOSAppOnMac {
            let keepAwakeOn = key.keepAwakeEnabled || key.screenSaverNowEnabled
            let keepAwakeMenu = UIMenu(
                title: AppLocalized("Keep Screen On"),
                image: UIImage(systemName: keepAwakeOn ? "sun.max.fill" : "sun.max"),
                children: [
                    UIAction(title: AppLocalized("Keep Screen On"),
                             image: UIImage(systemName: "sun.max"),
                             state: key.keepAwakeEnabled ? .on : .off) { _ in
                        coordinator.parent.setKeepAwake(!key.keepAwakeEnabled)
                    },
                    UIAction(title: AppLocalized("Use Screen Saver"),
                             image: UIImage(systemName: "moon.stars"),
                             state: key.screenSaverNowEnabled ? .on : .off) { _ in
                        coordinator.parent.setScreenSaverNow(!key.screenSaverNowEnabled)
                    },
                ])
            if keepAwakeOn { keepAwakeMenu.subtitle = AppLocalized("On") }
            sessionGroup.append(keepAwakeMenu)
        }
        groups.append(UIMenu(options: .displayInline, children: sessionGroup))

        // [T-codex-fast-mode-menu-group] Model-control toggles (they shape how
        // the MODEL is invoked, unlike the session-scoped rows above) live in
        // their own inline group so dividers separate them on both sides.
        var modelControlGroup: [UIMenuElement] = []
        if key.showEnhancedCacheToggle {
            modelControlGroup.append(UIAction(title: AppLocalized("Enhanced Cache"),
                                              image: UIImage(systemName: "clock.arrow.circlepath"),
                                              state: key.enhancedCacheEnabled ? .on : .off) { _ in
                coordinator.parent.setEnhancedCache(!key.enhancedCacheEnabled)
            })
        }
        // [T-codex-fast-mode] Only for Codex OAuth models. Injects
        // service_tier=priority (the wire value codex_cli_rs sends for its
        // Fast mode) into Codex requests while enabled; 2x credit burn.
        // [T-codex-speed-tier] A model with only Standard / Fast keeps the
        // unchanged single switch (existing users see no difference). With
        // Ultrafast offered, the switch becomes a "Speed" submenu of the three
        // mutually exclusive tiers; the row's subtitle names the current one.
        if key.showFastModeToggle && !key.showUltrafast {
            let fastOn = key.speedTier != .standard
            // [T-codex-speed-icons] Outline bolt, as Fast in the Speed submenu.
            modelControlGroup.append(UIAction(title: AppLocalized("Enable Fast Mode"),
                                              image: UIImage(systemName: SpeedTier.fast.symbol),
                                              state: fastOn ? .on : .off) { _ in
                coordinator.parent.setSpeedTier(fastOn ? .standard : .fast)
            })
        } else if key.showFastModeToggle {
            let tiers = SpeedTier.allCases.map { tier in
                UIAction(title: tier.title,
                         image: UIImage(systemName: tier.symbol),
                         state: key.speedTier == tier ? .on : .off) { _ in
                    coordinator.parent.setSpeedTier(tier)
                }
            }
            // [T-fast-mode-menu-name] Same entry name as the SwiftUI menu.
            let speedMenu = UIMenu(title: AppLocalized("Fast Mode"),
                                   image: UIImage(systemName: SpeedTier.entrySymbol),
                                   options: .singleSelection,
                                   children: tiers)
            speedMenu.subtitle = key.speedTier.title
            modelControlGroup.append(speedMenu)
        }
        if !modelControlGroup.isEmpty {
            groups.append(UIMenu(options: .displayInline, children: modelControlGroup))
        }

        var tailGroup: [UIMenuElement] = [
            UIAction(title: AppLocalized("Token Usage"),
                     image: UIImage(systemName: "number")) { _ in coordinator.parent.onTokenUsage() },
        ]
        #if DEBUG
        tailGroup.append(UIDeferredMenuElement.uncached { completion in
            // [T-ios-navbar-menu-baritem] UIKit runs this provider each time it
            // (re)fetches the open menu's content: one line per open is normal,
            // repeats during one open are the mid-stream refresh.
            ChatNavMenuBarItem.logger.info("[NavMenu] menu content fetched")
            let n = LastAPIRequestBody.shared.getAll().count
            completion([
                UIAction(title: "Copy Requests (\(n))",
                         image: UIImage(systemName: "arrow.up.doc")) { _ in coordinator.parent.onCopyRequests() },
                UIAction(title: "Copy Session Data",
                         image: UIImage(systemName: "tray.and.arrow.up")) { _ in coordinator.parent.onCopySessionData() },
            ])
        })
        #endif
        groups.append(UIMenu(options: .displayInline, children: tailGroup))

        return UIMenu(children: groups)
    }
}

// MARK: - "..." as a real UIBarButtonItem

/// [T-ios-navbar-menu-baritem] Switch + log for ChatNavMenuBarItemInstaller.
/// `chat.navMenu.barItem` (default on) picks the bar-item path; off restores
/// the ToolbarItem-hosted ChatTrailingMenuButton.
enum ChatNavMenuBarItem {
    static let logger = AppLogger(category: "NavMenu")
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "chat.navMenu.barItem") as? Bool ?? true
    }
}

/// [T-ios-navbar-menu-baritem] Puts the chat page's "..." on the hosting
/// controller's UINavigationItem as a plain `UIBarButtonItem(image:menu:)`.
///
/// Why: inside `ToolbarItem` the UIKit button is a SwiftUI-hosted custom
/// view, which the system can only leave where it is. On iOS 27's iPhone Duo
/// the system moves standard bar items (the home page's buttons, Back) into
/// the side column, but not this one. A real bar item with a menu is
/// something the system can place itself.
///
/// It keeps what ChatTrailingMenuButton fixed (the mid-stream menu refresh):
/// ONE UIBarButtonItem instance lives for the whole page and its `menu` is
/// replaced only when the displayed state changes.
///
/// Risk being measured: SwiftUI's toolbar bridge rewrites the navigation
/// item's bar buttons on its own updates, which can drop an item it does not
/// know about. The installer watches `rightBarButtonItems` (KVO, plus a check
/// after every SwiftUI update) and puts the same instance back, logging each
/// drop as `[NavMenu] reinstall`.
struct ChatNavMenuBarItemInstaller: UIViewRepresentable {
    let menu: ChatTrailingMenuButton

    final class AnchorView: UIView {
        var onWindowChange: ((AnchorView) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(self)
        }
    }

    final class Coordinator {
        let inner: ChatTrailingMenuButton.Coordinator
        let item: UIBarButtonItem
        weak var navItem: UINavigationItem?
        var observation: NSKeyValueObservation?
        var reinstalls = 0

        init(menu: ChatTrailingMenuButton) {
            inner = ChatTrailingMenuButton.Coordinator(parent: menu)
            let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            item = UIBarButtonItem(image: UIImage(systemName: "ellipsis", withConfiguration: cfg), menu: nil)
            // Same colour as ChatTrailingMenuButton. A bar item otherwise takes
            // the app tint; iOS 26's glass hides that, iOS 16-18 would show it.
            item.tintColor = UIColor(ChatColors.primaryText)
            item.accessibilityLabel = AppLocalized("More options")
            item.menu = ChatTrailingMenuButton.buildMenu(key: menu.key, coordinator: inner)
            inner.lastKey = menu.key
        }

        /// The controller whose navigationItem the bar shows for this page:
        /// the nearest ancestor controller that is a navigation controller's
        /// direct child.
        static func hostController(of view: UIView) -> UIViewController? {
            var responder: UIResponder? = view
            var fallback: UIViewController?
            while let r = responder {
                if let vc = r as? UIViewController {
                    if vc.parent is UINavigationController { return vc }
                    if fallback == nil, vc.navigationController != nil { fallback = vc }
                }
                responder = r.next
            }
            return fallback
        }

        func attach(from view: AnchorView) {
            guard view.window != nil else {
                detach(reason: "left window")
                return
            }
            guard let vc = Self.hostController(of: view) else {
                ChatNavMenuBarItem.logger.info("[NavMenu] no host controller yet")
                return
            }
            let target = vc.navigationItem
            if navItem !== target {
                detach(reason: "host changed")
                navItem = target
                // Fires for SwiftUI's own setRightBarButtonItems: calls too.
                observation = target.observe(\.rightBarButtonItems, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.ensureInstalled(reason: "kvo") }
                }
                ChatNavMenuBarItem.logger.info("[NavMenu] attach host=\(type(of: vc))")
            }
            ensureInstalled(reason: "attach")
        }

        func ensureInstalled(reason: String) {
            guard let navItem else { return }
            let items = navItem.rightBarButtonItems ?? []
            if items.contains(where: { $0 === item }) { return }
            navItem.rightBarButtonItems = [item] + items
            if reason != "attach" { reinstalls += 1 }
            ChatNavMenuBarItem.logger.info("[NavMenu] reinstall reason=\(reason) others=\(items.count) total=\(reinstalls)")
        }

        func detach(reason: String) {
            observation = nil
            guard let navItem else { return }
            if let items = navItem.rightBarButtonItems, items.contains(where: { $0 === item }) {
                navItem.rightBarButtonItems = items.filter { $0 !== item }
            }
            self.navItem = nil
            ChatNavMenuBarItem.logger.info("[NavMenu] detach reason=\(reason)")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(menu: menu) }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView(frame: .zero)
        view.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        view.onWindowChange = { [weak coordinator] anchor in coordinator?.attach(from: anchor) }
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AnchorView, context: Context) -> CGSize? {
        .zero
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        let coordinator = context.coordinator
        // Closures capture view state: refresh every pass (as ChatTrailingMenuButton).
        coordinator.inner.parent = menu
        if coordinator.inner.lastKey != menu.key {
            coordinator.inner.lastKey = menu.key
            coordinator.item.menu = ChatTrailingMenuButton.buildMenu(key: menu.key, coordinator: coordinator.inner)
            ChatNavMenuBarItem.logger.info("[NavMenu] menu rebuilt (displayed state changed)")
        }
        // The toolbar bridge pushes during this same update; check once it has.
        DispatchQueue.main.async { [weak coordinator] in coordinator?.ensureInstalled(reason: "update") }
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.detach(reason: "dismantle")
    }
}
