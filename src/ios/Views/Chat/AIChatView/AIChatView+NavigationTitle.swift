//
//  AIChatView+NavigationTitle.swift
//  Minis - chat page (AIChatView)
//
//  AIChatView, navigation title: the principal toolbar content hosted by
//  ChatToolbarHost and its equatable keys, the title / model selector view,
//  speed tier and fast-mode availability, the thinking-level badge, and the
//  session title snapshot used by the title pill.
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

extension AIChatView {
    // MARK: - Navigation Title + Model Selector

    /// [T-ios-navbar-toolbar-host] Principal toolbar content, extracted from
    /// the old inline ToolbarItem so ChatToolbarHost can render it. Layout
    /// preserved verbatim:
    /// [T-navbar-title-centering] iOS 18 and below let the principal toolbar
    /// item shrink to its content width and anchor it left-of-center; iOS 19+
    /// centers natively — wrap in an infinite-width HStack with bookend
    /// Spacers on legacy iOS, and cap the width to (screen − ~140pt chrome)
    /// so long titles truncate instead of pushing through the trailing menu.
    @ViewBuilder
    var chatNavPrincipalContent: some View {
        // Cap the title width to (screen − chrome) on ALL versions.
        //
        // [NavTitleGestureTruncation 2026-07-24] iOS 19+ previously left the
        // titleView unconstrained, letting the system principal toolbar decide
        // the truncation width from whatever space the left/right bar items
        // leave. During an INTERACTIVE pop (edge-swipe), the system snapshots
        // the nav bar and interpolates bar-item positions; at some drag/cancel
        // frames the principal's available width widens, so lineLimit(1) stops
        // truncating and a long title momentarily "un-truncates" to its full
        // form — a jarring jump when the user cancels the swipe. Pinning an
        // explicit, version-stable cap makes the truncation point identical in
        // the steady state and every transition frame, so the title never
        // pops to full. Does not affect normal-length titles (they're under
        // the cap). This is a MITIGATION of the system snapshot behavior, not
        // a fix of it: the top-crop of the snapshot itself is UIKit-level and
        // out of SwiftUI's reach.
        let cap = max(120, UIScreen.main.bounds.width - 140)
        if #available(iOS 19, *) {
            titleView
                .frame(maxWidth: cap)
        } else {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                titleView
                    .frame(maxWidth: cap)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// [T-ios-navbar-toolbar-host] Everything the toolbar DISPLAYS (principal
    /// title + trailing menu), snapshotted as one Equatable key gating the
    /// whole ToolbarContent rebuild.
    var chatToolbarKey: ChatToolbarKey {
        ChatToolbarKey(
            navTitle: navTitleKey,
            messagesEmpty: vm.messages.isEmpty,
            hasSession: vm.sessionId != nil,
            isForcePulling: isForcePulling,
            iCloudSyncEnabled: iCloudSyncEnabled,
            memoryEnabled: vm.memoryEnabled,
            speakEnabled: cached.vm.speakEnabled,
            showEnhancedCacheToggle: cached.vm.showEnhancedCacheToggle,
            enhancedCacheEnabled: cached.vm.enhancedCacheEnabled,
            showFastModeToggle: activeModelSupportsFastMode,
            speedTier: displayedSpeedTier,
            showUltrafast: activeModelSupportsUltrafast,
            keepAwakeEnabled: keepAwakeThisChat,
            screenSaverNowEnabled: screenSaverNowThisChat
        )
    }

    /// [T-codex-fast-mode] True when the session's active model can use Fast
    /// Mode. Broadened from Codex-OAuth-only to: ANY
    /// Responses-API provider + a gpt-family model. Concretely the request
    /// must travel the Responses API path — providerType .openAIResponses
    /// (any credential/base, e.g. sub2api relays, which pass service_tier
    /// through), or the genuine Codex OAuth route (.openAI + OAuth + no
    /// custom base) — and the model id must contain "gpt" (mirrors the
    /// official fast catalog: gpt-5.6-sol/terra/luna, gpt-5.5, gpt-5.4).
    /// [T-codex-speed-tier] The chosen tier (tier key, else the legacy Bool).
    private var storedSpeedTier: SpeedTier {
        SpeedTier(rawValue: speedTierRaw) ?? (codexFastModeEnabled ? .fast : .standard)
    }

    /// [T-codex-speed-tier] Ultrafast is offered on top of Fast only for a
    /// whitelisted model on the Responses / Codex OAuth route — never xAI,
    /// whose Priority Processing has no Ultrafast. The whitelist and why it is
    /// one: SpeedTierSettings.supportsUltrafast.
    var activeModelSupportsUltrafast: Bool {
        guard activeModelSupportsFastMode else { return false }
        let display = SessionModelDisplay(store: configStore, draftGroupId: vm.initialGroupId)
        guard let (instance, modelId) = display.resolvedInstanceAndModel(for: vm.sessionId),
              instance.providerType != .xAI else { return false }
        return SpeedTierSettings.supportsUltrafast(modelId: modelId)
    }

    /// [T-codex-speed-tier] The tier the menu and the badge show — the one the
    /// request will use: Ultrafast chosen but not offered for this model reads
    /// (and is sent) as Fast.
    var displayedSpeedTier: SpeedTier {
        guard activeModelSupportsFastMode else { return .standard }
        let stored = storedSpeedTier
        if stored == .ultrafast, !activeModelSupportsUltrafast { return .fast }
        return stored
    }

    var activeModelSupportsFastMode: Bool {
        let display = SessionModelDisplay(store: configStore, draftGroupId: vm.initialGroupId)
        guard let (instance, modelId) = display.resolvedInstanceAndModel(for: vm.sessionId) else { return false }
        // [T-xai-priority-processing] xAI Priority Processing is the same
        // user-facing feature (pay more, go faster) reached through the same
        // "…" menu switch, so xAI models offer it too. Checked BEFORE the
        // gpt-family guard below: xAI ships grok-*, so requiring "gpt" in the
        // model id would silently never show the switch. Provider-type match
        // rather than a URL sniff, mirroring how the OpenAI branches identify
        // their route; the request-side `isXAI` host check in OpenAIProvider
        // stays as the second gate.
        if instance.providerType == .xAI { return true }
        guard modelId.lowercased().contains("gpt") else { return false }
        if instance.providerType == .openAIResponses { return true }
        return instance.providerType == .openAI
            && instance.credentialType == .oauth
            && (instance.customBaseURL?.isEmpty ?? true)
    }

    /// [T-ios-navbar-principal-streaming-stability] Snapshot of everything
    /// titleView displays — must stay in lockstep with titleView's reads
    /// (see NavTitleKey doc). Cheap to compute per body pass.
    private var navTitleKey: NavTitleKey {
        #if DEBUG
        NavbarEvalStats.toolbarPass += 1
        #endif
        let display = SessionModelDisplay(store: configStore, draftGroupId: vm.initialGroupId)
        let resolved = display.resolvedDetail(for: vm.sessionId)
        let sessionTitle: String? = (titlePillSession?.title?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
        return NavTitleKey(
            sessionTitle: sessionTitle,
            canEditTitle: titlePillSession != nil,
            soulName: soulName,
            modelName: display.displayName(for: vm.sessionId),
            isGroupBound: display.isGroupBound(for: vm.sessionId),
            speedBadge: displayedSpeedTier,
            resolvedText: resolved.map { "\($0.providerLabel) · \($0.modelName)" },
            hasBinding: vm.sessionId != nil && configStore.binding(for: vm.sessionId!) != nil,
            hasProviders: !configStore.instances.isEmpty,
            showThinkingBadge: !vm.availableThinkingLevels.isEmpty
                && (vm.currentThinkingLevel.isEnabled || vm.currentModelSupportsReasoning),
            thinkingLevelName: vm.currentThinkingLevel.displayName,
            fallbackTrigger: vm.fallbackTrigger,
            fallbackPulse: fallbackPulseOpacity,
            titleLocked: titleIsVisuallyLocked
        )
    }

    private var titleView: some View {
        let display = SessionModelDisplay(store: configStore, draftGroupId: vm.initialGroupId)
        let modelName = display.displayName(for: vm.sessionId)
        let isGroupBound = display.isGroupBound(for: vm.sessionId)
        let resolved = display.resolvedDetail(for: vm.sessionId)
        let hasBinding = vm.sessionId != nil && configStore.binding(for: vm.sessionId!) != nil
        let hasProviders = !configStore.instances.isEmpty

        let isAuthed = hasBinding || hasProviders
        // [T-quota-low-dot] The entry this chat runs on (cached per config /
        // auth revision), for the status dot's quota warning.
        let currentEntry = vm.resolveCurrentEntry()
        let quotaLow = isAuthed && ModelQuotaStatusDot.isLow(instanceId: currentEntry?.providerInstanceId,
                                                             modelId: currentEntry?.baseModel.id)

        let legacyLayout = !ProcessInfo.processInfo.isiOSAppOnMac && {
            if #available(iOS 26, *) { return false }
            return true
        }()

        // Use the current session's title in place of the default name
        // when one exists (auto-generated or user-renamed). Tap opens the
        // same SessionEditSheet used from the home screen so users can
        // rename / re-categorize without leaving the chat. Falls back to
        // the SOUL.md `name` (or "Minis") for draft sessions or before a
        // title has been generated.
        let sessionTitle: String? = (titlePillSession?.title?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
        let canEditTitle = titlePillSession != nil

        // [NavTitleClip 2026-05-16] On iOS 26 the principal toolbar
        // container clipped the top of the title and the bottom of the
        // resolved-detail subtitle when a 3-line stack was used. Adding
        // a small top inset shifts the whole VStack downward into the
        // visible band; the toolbar happily renders it without
        // truncation. Legacy (iOS < 26) layout already used a -6 stack
        // spacing trick and doesn't need the inset.
        //
        // [NavTitleDescenderClip 2026-05-18] Tighten the outer VStack
        // from 0 to -2pt on iOS 26 so the three rows pack more closely
        // and free up vertical room for descenders ("g", "p", "y") on
        // the resolved-detail line (e.g. "Fake Hang 1" was clipping the
        // final "1" / "g" baseline at the navbar bottom). -2pt is the
        // sweet spot: overlap is invisible at 9pt body text but recovers
        // ~2pt of descender clearance below the third row.
        // [T-navbar-title-clip 2026-05-21] After shrinking the legacy
        // title to 13pt the stack was tall enough to clear the top of
        // the navbar but visually it now sat *too high* — the title
        // row clipped at the status-bar edge while the model-name row
        // had a tall empty gap below it before the navbar's bottom
        // separator. Root cause: SwiftUI doesn't strictly center the
        // `.principal` item on iOS 16-18; it baseline-aligns to the
        // navigation bar's title text baseline. Padding the OUTER
        // stack downward (`.padding(.top, …)` on the VStack itself)
        // pushes the whole title region down within the band without
        // changing its rendered height. Legacy-only — iOS 26 already
        // sits correctly in the liquid-glass band.
        // [T-navbar-title-model-gap 2026-07-18] Legacy spacing -8 → -3. The
        // 2026-05-20 tightening overlapped row 2 into the title's line box by
        // 8pt — more than the 13pt font's entire descender zone (~3.1pt), so
        // any title containing g/p/y/z visually fused with the model pill
        // (only descender-less titles like "Minis" hid it). -3 keeps a ~2pt
        // visible gap for descender titles. HEIGHT-NEUTRAL: the 5pt spent
        // here is reclaimed inside row 2 (provider-row bottom clearance
        // 4 → 1 and group vertical padding 3 → 2 on legacy), so the stack's
        // total height — the thing the May-18/19/20 clip saga fought — is
        // unchanged and the top-clip fix does not regress.
        return VStack(spacing: legacyLayout ? -3 : -2) {
            Button {
                if let s = titlePillSession { titlePillEditSession = s }
            } label: {
                // [T-navbar-title-size 2026-05-18] iOS 18 and below render
                // the principal toolbar in a tighter band than iOS 26's
                // liquid-glass navbar — long CJK titles (e.g. a
                // "Download and merge Twitter video" style CJK string)
                // overflowed at 16pt on iPhone Mini/SE and
                // wrapped under the trailing "…" button. Drop one point
                // on legacy iOS so they fit cleanly; keep the iOS 26
                // size unchanged.
                Text(sessionTitle ?? soulName)
                    // [T-navbar-title-size 2026-05-18 / -19 / -20] iOS 16-18
                    // principal toolbar is a fixed ~44pt band sitting just
                    // below the status bar with very little reserved padding.
                    // A 3-line title stack at 16pt/.caption2/9pt overflowed
                    // the band's top against the status-bar / Dynamic Island
                    // cutoff (a tall CJK glyph clipped its top, then "?"
                    // appeared because the glyph rect was outside the navbar
                    // viewport). Iterative tightening:
                    //   2026-05-18: 16 → 15pt + `padding(.top, 2)`
                    //   2026-05-19: 15 → 13.5pt + `minimumScaleFactor(0.85)`
                    //                 + `fixedSize(...)` + `padding(.top, 3)`
                    //   2026-05-20: 13.5 → 13pt + drop padding(.top) to 0 +
                    //                 outer VStack spacing -6 → -8. Earlier
                    //                 attempts to push the stack DOWN with
                    //                 more padding.top failed because SwiftUI
                    //                 vertically CENTERS the .principal item
                    //                 in the navbar — extra height clips
                    //                 BOTH top and bottom equally, not just
                    //                 the bottom. Net result: shrink the
                    //                 total stack height instead, so it
                    //                 naturally has breathing room above
                    //                 and below.
                    // iOS 26 path unchanged (16pt works inside liquid-glass).
                    .font(.system(size: legacyLayout ? 13 : 16, weight: .semibold))
                    .minimumScaleFactor(legacyLayout ? 0.85 : 1.0)
                    .foregroundStyle(ChatColors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    // [NavTitleTopClip 2026-07-23] Was 4pt on iOS 26 to shove
                    // the title into the visible band, but combined with the
                    // now-centered 46pt frame it pushed the title's top past
                    // the clip line again. 4 → 2: the centered frame already
                    // positions the stack correctly, and 2pt keeps a little
                    // breathing room above the semibold cap height without
                    // re-introducing the top crop.
                    .padding(.top, legacyLayout ? 0 : 2)
                    .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
                        let n = SoulStore.cachedMetadata.name
                        soulName = n.isEmpty ? "Minis" : n
                    }
            }
            .buttonStyle(.plain)
            .disabled(!canEditTitle)

            // [T-navbar-group-provider-gap 2026-07-25] Legacy row gap 1 → -1:
            // on iOS 16-18 the provider·model line (row 2) sat flush against
            // the navbar band's bottom edge (field screenshot: group name and
            // row 2 had a visibly larger gap than row 2 had bottom clearance).
            // Tightening ONLY the group↔provider gap moves row 2 up inside
            // the band, giving the last line breathing room from the bottom.
            // -1 still leaves ~2pt visual space (caption2's descender zone +
            // the 9pt row's cap headroom); the calibrated title↔group overlap
            // (outer -3) and the group pill's vertical padding are untouched.
            // iOS 26 keeps spacing 1 — the liquid-glass band has no crowding.
            VStack(spacing: legacyLayout ? -1 : 1) {
                HStack(spacing: 4) {
                    Button {
                        showModelPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            // [T-quota-low-dot] green / yellow (quota low) / orange (signed out).
                            ModelQuotaStatusDot(isAuthed: isAuthed,
                                                instanceId: currentEntry?.providerInstanceId,
                                                modelId: currentEntry?.baseModel.id)
                            if isGroupBound {
                                Image(systemName: "square.stack.3d.up")
                                    .font(.system(size: 8))
                                    .foregroundStyle(ChatColors.tertiaryText)
                            }
                            Text(modelName)
                                .font(.caption2)
                                .foregroundStyle(ChatColors.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(ChatColors.tertiaryText)
                        }
                        .layoutPriority(-1)
                    }
                    .buttonStyle(.plain)
                    // [T-ios-voiceover-labels] This label is assembled from a
                    // status dot, an optional group glyph, the model name and a
                    // chevron. Left alone VoiceOver reads those as disconnected
                    // fragments ("square stack 3d up", "chevron down"), so
                    // combine the row into one element and state what it is.
                    // The connection state and group binding are carried as the
                    // VALUE rather than folded into the label, so VoiceOver
                    // keeps them distinguishable from the control's name.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Model", comment: "VoiceOver label for the model picker button"))
                    .accessibilityValue(Text(
                        isGroupBound
                            ? (isAuthed
                                ? AppLocalized("\(modelName), group, signed in", comment: "VoiceOver value: model picker, group-bound, authenticated")
                                : AppLocalized("\(modelName), group, not signed in", comment: "VoiceOver value: model picker, group-bound, not authenticated"))
                            : (isAuthed
                                ? AppLocalized("\(modelName), signed in", comment: "VoiceOver value: model picker, authenticated")
                                : AppLocalized("\(modelName), not signed in", comment: "VoiceOver value: model picker, not authenticated"))
                    ) + Text(quotaLow ? AppLocalized(", quota low", comment: "VoiceOver: appended to the model value when the model's quota or balance is low") : ""))
                    .accessibilityHint(Text("Opens the model picker", comment: "VoiceOver hint for the model picker button"))
                    .accessibilityAddTraits(.isButton)
                }

                if let detail = resolved {
                    // Row 2: "provider · model" + the thinking-level badge as a
                    // SEPARATE tappable sibling (not nested in the model-picker
                    // Button) so the badge opens ThinkingLevelSheetView while the
                    // text still opens the model picker — mirroring how row 1's
                    // model-name Button and badge were laid out. The model name
                    // truncates first (layoutPriority(-1) + lineLimit(1)); the
                    // badge keeps its intrinsic size and always shows in full.
                    HStack(spacing: 4) {
                        // [T-codex-fast-mode] Speed badge in front of the resolved
                        // model line (row 3) while a faster tier applies.
                        // User-requested placement: this row names the actual
                        // model; row 2 may show a group name instead.
                        // [T-codex-speed-icons] One monochrome SF Symbol, the
                        // same glyphs as the Speed menu: outline bolt = Fast,
                        // filled bolt = Ultrafast.
                        // [T-speed-badge-height] Scaled to the model name's cap
                        // height instead of set as a 9pt glyph: a bolt at a 9pt
                        // font stands well above the letters beside it and reads
                        // as a stray, oversized mark in this small row.
                        if let symbol = displayedSpeedTier.badgeSymbol {
                            Image(systemName: symbol)
                                .resizable()
                                .scaledToFit()
                                .frame(height: ceil(UIFont.systemFont(ofSize: 9).capHeight))
                                .foregroundStyle(Color.orange)
                                // Match the row text's descender clearance so
                                // the badge centers on the same visual band.
                                .padding(.bottom, legacyLayout ? 1 : 4)
                                .accessibilityLabel(Text(verbatim: displayedSpeedTier.title))
                        }
                        Button {
                            showModelPicker = true
                        } label: {
                            Text("\(detail.providerLabel) · \(detail.modelName)")
                                .font(.system(size: 9))
                                .foregroundStyle(ChatColors.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                // [NavTitleClip 2026-05-16] Reserve clearance
                                // under the resolved-detail line so the final
                                // glyph descenders ("g","p","y") don't touch
                                // the navbar's bottom safe-area cutoff on
                                // iOS 26. 2 → 4pt: 2 wasn't enough when text
                                // included descenders ("Fake Hang 1" clipped
                                // the lowered "1" stroke).
                                // [T-navbar-title-model-gap] Legacy needs only
                                // 1pt — the 4pt clearance is an iOS 26
                                // liquid-glass-band requirement; on 16-18 it
                                // was pure height waste, now traded into the
                                // title→model gap (see the outer VStack).
                                .padding(.bottom, legacyLayout ? 1 : 4)
                                // Force vertical sizing to fit the full
                                // glyph including descender so the line's
                                // own frame doesn't crop before the navbar
                                // gets a chance to lay it out.
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(-1)
                        }
                        .buttonStyle(.plain)
                        // Show the badge whenever thinking is enabled, and ALSO
                        // when it's Off but the active model supports deep
                        // thinking — the icon + "Off" pill is then a discoverable
                        // entry point for turning it on (tap opens the level
                        // sheet). The Off pill is gated on
                        // `currentModelSupportsReasoning` so non-reasoning models
                        // don't grow a dead toggle; an enabled level still shows
                        // unconditionally (user may have opted in on an
                        // unknown-capability model).
                        if !vm.availableThinkingLevels.isEmpty,
                           vm.currentThinkingLevel.isEnabled || vm.currentModelSupportsReasoning {
                            thinkingLevelBadge
                                .fixedSize()
                                // Match the model-name line's descender
                                // clearance so the badge sits on the same
                                // baseline band and isn't clipped at the
                                // navbar's bottom cutoff.
                                // [T-navbar-title-model-gap] Match the
                                // provider text's legacy clearance.
                                .padding(.bottom, legacyLayout ? 1 : 4)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            // [T-navbar-title-model-gap] 3 → 2 on legacy: part of the
            // height-neutral trade that funds the wider title→model gap.
            .padding(.vertical, legacyLayout ? 2 : 3)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.35 * fallbackPulseOpacity))
            )
            .onChange(of: vm.fallbackTrigger) { _ in
                // 3× pulse: fade in then out, repeated 3 times
                fallbackPulseOpacity = 0
                withAnimation(.easeInOut(duration: 0.35)) {
                    fallbackPulseOpacity = 1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeInOut(duration: 0.35)) { fallbackPulseOpacity = 0 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    withAnimation(.easeInOut(duration: 0.35)) { fallbackPulseOpacity = 1 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
                    withAnimation(.easeInOut(duration: 0.35)) { fallbackPulseOpacity = 0 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    withAnimation(.easeInOut(duration: 0.35)) { fallbackPulseOpacity = 1 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.75) {
                    withAnimation(.easeInOut(duration: 0.35)) { fallbackPulseOpacity = 0 }
                }
            }
        }
        // [T-navbar-title-clip 2026-05-21] Nudge the whole legacy title
        // stack down so the first row clears the status-bar / Dynamic
        // Island band. iOS 16-18 baseline-aligns the `.principal` item
        // to the toolbar title baseline — adding top padding on the
        // OUTER stack shifts its rendered position downward without
        // resizing any individual row. iOS 26 leaves at 0 (liquid
        // glass centers correctly).
        .padding(.top, legacyLayout ? 6 : 0)
        // iOS 26+: fix height to match liquid-glass navbar; older OS: let it size naturally
        .modifier(NavTitleFrameModifier())
        // [T-navbar-title-fontsize] Lock the entire principal-toolbar
        // title stack to the standard (.large) Dynamic Type size. Users
        // with system / app font scaling cranked up were having the
        // model name + "provider · model" subtitle overflow the navbar
        // band and clip. The numeric sizes used above (16/.caption2/9)
        // still scale with Dynamic Type by default; clamping the
        // environment here freezes them at the design baseline without
        // having to rewrite every Text modifier individually.
        .dynamicTypeSize(.large)
        // Blur the title (and model/provider subtitle) while the session
        // is locked, mirroring the chat body's SessionLockGateOverlay.
        // `SessionLockStore.isVisuallyLocked` is the single source of
        // truth — the same helper drives the gate overlay and the chat
        // list row, so all three sites lock and unlock in lockstep.
        .blur(radius: titleIsVisuallyLocked ? 8 : 0)
        .allowsHitTesting(!titleIsVisuallyLocked)
        .animation(.easeInOut(duration: 0.15), value: titleIsVisuallyLocked)
    }

    @ViewBuilder
    private var thinkingLevelBadge: some View {
        let level = vm.currentThinkingLevel
        // Sits on nav-bar row 2 (the 9pt "provider · model" line). Kept a
        // touch smaller than that text (8pt / 6px icon) so it stays the most
        // compact label in the title and never larger than the "is thinking…"
        // intensity pill in the message list.
        //
        // Also rendered when the level is Off (reasoning-capable model with
        // thinking disabled): the pill then reads icon + "Off" as a tap target
        // for enabling deep thinking. Dim the icon in that state — matches the
        // 0.4 Off-row convention in ThinkingLevelSheetView.
        HStack(spacing: 2) {
            Image("ThinkingIcon")
                .resizable()
                .frame(width: 6, height: 6)
                .opacity(level.isEnabled ? 1.0 : 0.4)
            Text(level.displayName)
                .font(.system(size: 8, weight: .medium))
        }
        .foregroundStyle(ChatColors.secondaryText)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.10)))
        .onTapGesture {
            showThinkingLevelSheet = true
        }
        .sheet(isPresented: $showThinkingLevelSheet) {
            ThinkingLevelSheetView(
                currentLevel: level,
                availableLevels: vm.availableThinkingLevels,
                onSelect: { newLevel in
                    vm.setThinkingLevel(newLevel)
                    showThinkingLevelSheet = false
                }
            )
            .presentationDetents([.medium])
        }
    }

    /// True when the current session's navbar title must render blurred —
    /// observed via `@ObservedObject lockStore` so toggles to the lock
    /// state push a re-render of the toolbar synchronously with the gate.
    private var titleIsVisuallyLocked: Bool {
        guard let sid = vm.sessionId, !sid.isEmpty else { return false }
        return lockStore.isVisuallyLocked(sid)
    }

    // MARK: - Session Title Snapshot

    func refreshTitlePillSession() {
        guard let sid = vm.sessionId else {
            titlePillSession = nil
            return
        }
        // ChatStore is an actor — must await off the main actor. Bouncing
        // back to the main actor before mutating @State avoids the strlen /
        // SQLite data race that crashed when called synchronously from the
        // view body (concurrent with sync engine writes).
        Task {
            let next = await ChatStore.shared.getSession(sid)
            await MainActor.run {
                guard sid == vm.sessionId else { return }
                if next?.id != titlePillSession?.id
                    || next?.title != titlePillSession?.title
                    || next?.category != titlePillSession?.category {
                    // Direct replace — animating the toolbar title makes the
                    // old "Minis" string slide before the real title swaps
                    // in, which looks broken. SwiftUI's default crossfade
                    // for non-animated text changes is what we want.
                    titlePillSession = next
                }
            }
        }
    }
}
