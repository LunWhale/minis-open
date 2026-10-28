//
//  SidebarSurfaces.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  View modifiers and backgrounds of the sidebar: selection opt-out, folder
//  header visibility probe, folder card / member-row surfaces (one source of
//  truth for the folder look), and the search bar / FAB glass styling.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

/// List-selection opt-out with an availability floor. The folder card row
/// must never become the List(selection:)'s selected value — its "tap" is
/// collapse/expand, not navigation — but .selectionDisabled is iOS 17+ and
/// the app floors at 16 (where the plain Button row doesn't self-select).
struct SelectionDisabledIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.selectionDisabled()
        } else {
            content
        }
    }
}

/// Tracks whether an expanded folder's header card has scrolled out above
/// the list's visible top, reporting only on TRANSITIONS (Bool onChange) so
/// scroll frames don't churn ContentView state. Lives in the header row's
/// background — geometry is read in .global and compared against the
/// threshold the mini-bar overlay measured, which sidesteps the known-flaky
/// preference propagation across List cell hosting boundaries entirely.
///
/// `lastMaxY` exists for the CULLING edge: when the List recycles the header
/// cell far offscreen, onDisappear is the only signal left, and it alone
/// can't tell "culled above" from "culled below". The last observed frame
/// disambiguates. onDisappear also fires on collapse and on entering select
/// mode (the header row unmounts) — those reports are harmless because the
/// mini-bar's display guard independently requires an expanded folder
/// outside select mode.
struct FolderHeaderVisibilityProbe: View {
    let folderId: String
    let thresholdY: CGFloat
    let onVisibilityChange: (String, Bool) -> Void

    @State private var lastMaxY: CGFloat = .infinity

    var body: some View {
        GeometryReader { geo in
            let maxY = geo.frame(in: .global).maxY
            let hidden = maxY < thresholdY
            Color.clear
                .onAppear {
                    lastMaxY = maxY
                    onVisibilityChange(folderId, hidden)
                }
                .onChange(of: maxY) { newValue in
                    lastMaxY = newValue
                }
                .onChange(of: hidden) { newValue in
                    onVisibilityChange(folderId, newValue)
                }
                .onDisappear {
                    onVisibilityChange(folderId, lastMaxY < thresholdY)
                }
        }
    }
}

/// Folder card container: what visually separates a folder from the flat
/// session rows around it. On iOS 26+ this is the system Liquid Glass
/// material (`glassEffect`) in a continuous rounded rect; on earlier systems
/// it degrades to a deliberately plain filled card with a hairline stroke —
/// no custom blur, since `.blur` is an offscreen pass and this list is the
/// site of two archived scroll-perf incidents. The drop-target state draws an
/// accent tint + stroke ON TOP of either material, so drag feedback reads the
/// same on both OS generations.
/// One row's share of the expanded container's OUTER border. The top kind
/// draws the top arc + upper side walls, middle draws side walls only, and
/// bottom draws the lower walls + bottom arc — tiled across the group's rows
/// they form one continuous rounded-rect highlight, with no horizontal lines
/// at the row boundaries (which a per-segment full stroke would create).
private struct FolderSegmentBorder: Shape {
    enum Kind { case top, middle, bottom }
    let kind: Kind
    var radius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch kind {
        case .top:
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            p.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
                     radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            p.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
                     radius: radius, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .middle:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottom:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
            p.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
                     radius: radius, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
            p.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                     radius: radius, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        return p
    }
}

/// Edge highlight for the simulated glass: bright hairline in dark mode
/// (the reference system-folder look), a subtle dark line in light mode
/// (white would vanish on the light page).
private let folderEdgeHighlight = Color(UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.30)
        : UIColor(white: 0, alpha: 0.08)
})

/// Background for the expanded FAB search bar. Liquid Glass capsule on iOS 26+,
/// the original opaque capsule + hand-rolled shadow below it.
///
/// A modifier rather than a background view because the bar's content has to sit
/// INSIDE the glass: `.glassEffect` styles the view it is applied to, so the
/// text field and its icons ride within the material instead of being composited
/// over a separately-drawn shape.
struct SearchBarSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // No .clipShape needed — glassEffect(in:) already clips to the
            // capsule, and no .shadow: the material carries its own.
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)
        }
    }
}

/// Tags the search FAB and the expanded search bar with ONE shared
/// `glassEffectID`.
///
/// Currently INERT: `glassEffectID` only does anything inside a
/// `GlassEffectContainer`, and the FAB row no longer has one — that container
/// suppressed the new-chat FAB's context menu, see the note on `fabRow`. The
/// modifier is kept (harmless, and it costs nothing) so that if the container
/// is ever reinstated with the menu problem solved, the morph works again
/// without re-deriving the id plumbing. The row's scale+opacity transition is
/// what actually animates the swap today.
struct FABGlassMorphID: ViewModifier {
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffectID("fabSearch", in: namespace)
        } else {
            content
        }
    }
}

/// THE single source of truth for a folder surface's background — used
/// identically by the collapsed lone card and by every row of an expanded
/// group. Per the user's directive after several rounds of expanded-only
/// material tuning: there is NO expanded-specific material/tint/opacity
/// definition anymore. The only thing that varies by position is the SHAPE
/// (lone / top / middle / bottom corner segmentation) and how the border is
/// tiled; the fill comes from one place.
private struct FolderSurface: ViewModifier {
    enum Kind { case lone, top, middle, bottom }
    let kind: Kind

    /// The collapsed card's ACTUAL rendered color, eyedropper-sampled from
    /// device screenshots. Dark: RGB 18/18/18 — re-sampled with a probe
    /// build rendering REAL glass over a pure-black list with no pinned rows
    /// behind it (24 points, zero variance). The earlier 57/57/60 was
    /// contaminated: that screenshot's card had blurred colorful content
    /// showing through the glass, and the too-light constant is what read as
    /// a heavy solid slab against the black page. True glass sits nearly on
    /// the background and lets the edge hairline do the lifting — that IS
    /// the lightweight look. Light: RGB 252/252/252 (sampled over a clean
    /// light background, unaffected).
    /// Used for the expanded segments on iOS 26 instead of per-row
    /// glassEffect: glass pieces cannot merge across List rows (edge lines
    /// between every segment — twice rejected), and in THIS context glass
    /// has nothing to blur behind it (the container sits on the flat list
    /// background), so its rendered output IS effectively this constant
    /// color. Sampling it gives pixel-level brightness parity with the
    /// collapsed card, perfectly seamless tiling, and zero perf risk —
    /// chosen by the user over a preference-propagation spike.
    static let sampledGlassColor = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 18/255.0, green: 18/255.0, blue: 18/255.0, alpha: 1)
            : UIColor(red: 252/255.0, green: 252/255.0, blue: 252/255.0, alpha: 1)
    })

    private var shape: AnyShape {
        switch kind {
        case .lone:
            return AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .top:
            return AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: 16, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 16, style: .continuous))
        case .middle:
            return AnyShape(Rectangle())
        case .bottom:
            return AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 16,
                bottomTrailingRadius: 16, topTrailingRadius: 0, style: .continuous))
        }
    }

    func body(content: Content) -> some View {
        Group {
            // Two states, two deliberate treatments (user decision):
            // - COLLAPSED lone card: the sampled constant. glassEffect is a
            //   live material and a collapsed card scrolls past heterogeneous
            //   content (blurred colorful pinned rows), so live glass
            //   flickered frame to frame; the constant is what that glass
            //   rendered over the flat background anyway.
            // - EXPANDED segments: a real material for translucency. Member
            //   rows sit over the STABLE list background only — nothing
            //   colorful ever passes behind them — so the flicker mechanism
            //   doesn't apply, and the material keeps the container from
            //   reading as a dull solid slab. regularMaterial (the brighter
            //   tier; ultraThin ran too dark here before).
            if kind == .lone {
                if #available(iOS 26.0, *) {
                    content.background(shape.fill(Self.sampledGlassColor))
                } else {
                    content.background(shape.fill(Color(UIColor.secondarySystemBackground)))
                }
            } else {
                if #available(iOS 26.0, *) {
                    content.background(shape.fill(.regularMaterial))
                } else {
                    content.background(shape.fill(Color(UIColor.secondarySystemBackground)))
                }
            }
        }
        .overlay {
            // Border: full hairline on the lone card (its existing look, sub-26
            // only — glass carries its own edge); tiled outer-perimeter
            // segments on expanded rows so the pieces read as one outline
            // without horizontal lines at the row boundaries.
            switch kind {
            case .lone:
                // With glass gone the card needs an explicit edge for
                // definition — the same highlight the expanded segments tile,
                // as a full perimeter here.
                if #available(iOS 26.0, *) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(folderEdgeHighlight, lineWidth: 0.75)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(UIColor.separator).opacity(0.5), lineWidth: 0.5)
                }
            case .top:
                FolderSegmentBorder(kind: .top)
                    .stroke(folderEdgeHighlight, lineWidth: 0.75)
            case .middle:
                FolderSegmentBorder(kind: .middle)
                    .stroke(folderEdgeHighlight, lineWidth: 0.75)
            case .bottom:
                FolderSegmentBorder(kind: .bottom)
                    .stroke(folderEdgeHighlight, lineWidth: 0.75)
            }
        }
    }
}

struct FolderCardBackground: ViewModifier {
    let isDropTarget: Bool
    let isExpanded: Bool

    private var dropShape: AnyShape {
        isExpanded
            ? AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: 16, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 16, style: .continuous))
            : AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    func body(content: Content) -> some View {
        content
            .modifier(FolderSurface(kind: isExpanded ? .top : .lone))
            .overlay {
                if isDropTarget {
                    ZStack {
                        dropShape.fill(Color.accentColor.opacity(0.15))
                        dropShape.stroke(Color.accentColor, lineWidth: 1.5)
                    }
                }
            }
    }
}

/// Middle/bottom rows of an expanded group: the SAME FolderSurface as the
/// collapsed card, with the corner segmentation and border tiling that
/// multi-row composition needs.
struct FolderMemberRowBackground: View {
    let isLast: Bool

    var body: some View {
        Color.clear
            .modifier(FolderSurface(kind: isLast ? .bottom : .middle))
            .padding(.horizontal, 6)
            .padding(.bottom, isLast ? 4 : 0)
    }
}

/// Rename + dissolve alerts for the folder-header menu, extracted into a
/// modifier so their inline Binding(get:set:) expressions don't count against
