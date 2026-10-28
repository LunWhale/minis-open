//
//  BridgedAssistantHeaderV3.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Cell content for the assistant header row ("✦ <name>" from SOUL.md; tap
//  opens Soul Settings). Hosted by AssistantHeaderCellV3 via the Coordinator's
//  cell provider (+CellConfiguration).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

// MARK: - V3 Bridged Cell Views (no GeometryReader)

/// Header: "✦ Minis" label at the top of each assistant turn.
/// Name comes from SOUL.md (user-editable in Soul Settings).
///
/// [T-ios-assistant-header-open-soul] Tapping the row opens Soul Settings.
/// The row shows the identity the user configured there, so it is the
/// obvious place to reach for when changing it.
struct BridgedAssistantHeaderV3: View {
    @ObservedObject var message: ChatMessage
    var maxWidth: CGFloat = 0
    @State private var soulMeta: SoulMetadata = SoulStore.cachedMetadata
    /// [T-ios-assistant-header-open-soul] Injected, NOT read from the
    /// environment.
    ///
    /// `\.openMinisURL` is set on AIChatView, but each cell here is hosted in
    /// its own `UIHostingConfiguration`, which starts a fresh SwiftUI hierarchy
    /// rather than inheriting that one. Reading the environment inside a cell
    /// therefore silently yields the key's default — an action that returns
    /// `.systemAction` and does nothing. (Verified on device: the tap fired, no
    /// navigation happened, and no deep-link log line appeared.) So the handler
    /// is threaded down the same way every other cell callback already is.
    var onOpenSoulSettings: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            // [T-soul-custom-icon] Honours a user-chosen emoji or image;
            // falls back to the gradient sparkle when unset, so headers for
            // users who never customized are pixel-identical to before.
            // The icon is square by construction (SoulIconImage.encode
            // crops), so an image cannot make this row taller than a glyph
            // does. At 22pt it now exceeds the .body cap-height beside it,
            // so it — not the text — sets the row height; the estimated
            // height seed below was re-measured to match.
            SoulIconView(
                icon: soulMeta.icon,
                size: 22,
                sparkleGradient: LinearGradient(
                    colors: [Color(red: 0.72, green: 0.69, blue: 0.59),
                             Color(red: 0.6, green: 0.6, blue: 0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                cornerRadius: 5
            )
            Text(soulMeta.name.isEmpty ? "Minis" : soulMeta.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(ChatColors.primaryText)
        }
        // [T-ios-assistant-header-open-soul] Hit area and tap, applied to the
        // icon+name HStack only — NOT to the full-width row below it.
        //
        // The `.frame(maxWidth: .infinity)` modifiers further down stretch this
        // header across the whole message column; making that tappable would
        // turn the empty space beside the name into a button and swallow taps
        // meant for the transcript.
        //
        // `contentShape` makes the whole icon+name box (including the 6pt gap)
        // hittable rather than only the glyph and text pixels.
        //
        // On the 44pt HIG target: the row is deliberately NOT grown to 44pt.
        // This header measures ~30pt (icon-driven since 22pt) and the cell
        // height is UIKit-self-sized, so enlarging the frame would
        // shift every assistant message in the transcript — the task explicitly
        // asks not to disturb layout. Instead the touch target is widened
        // horizontally (the tappable box spans icon + gap + full name, well
        // over 44pt across) and the 28pt height is left alone. That is the
        // trade the surrounding code forces; growing it would need the height
        // constant re-measured, which is out of scope here.
        .contentShape(Rectangle())
        .onTapGesture { onOpenSoulSettings?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(AppLocalized("Open Soul settings"))
        .accessibilityHint(AppLocalized("Change the assistant's name, icon and personality"))
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            soulMeta = SoulStore.cachedMetadata
        }
        .padding(.top, 4)
        .padding(.bottom, 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxWidth: maxWidth > 0 ? maxWidth : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier("assistantHeader")
    }
}
