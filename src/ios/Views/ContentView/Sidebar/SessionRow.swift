//
//  SessionRow.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  Session list rows and their parts: the category icon map, folder composed
//  icon, SessionRow, FolderSummaryLine, the Face ID lock effect,
//  RemoteSessionRow and the suspended ring.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

// MARK: - Session Row

/// category → (SF Symbol, color) for a session's list icon.
///
/// Single source of truth shared by `SessionRow`, `RemoteSessionRow`, and the
/// folder header's composed icon (which stacks the top members' glyphs). It
/// was previously duplicated as two identical private computed properties on
/// the row structs; the composed icon made a third copy untenable.
/// Pure function — safe to call from the `groupedSessions` aggregation pass.
func sessionCategoryIcon(for category: String?) -> (systemName: String, color: Color) {
    switch category {
    case "code":         return ("terminal.fill", .orange)
    case "writing":      return ("doc.text.fill", .blue)
    case "research":     return ("globe.americas.fill", .teal)
    case "analysis":     return ("chart.pie.fill", .indigo)
    case "creative":     return ("paintbrush.pointed.fill", .pink)
    case "chat":         return ("bubble.left.fill", .green)
    case "math":         return ("number.circle.fill", .purple)
    case "translation":  return ("character.bubble", .cyan)
    case "health":       return ("heart.fill", .red)
    case "finance":      return ("banknote.fill", .mint)
    case "travel":       return ("map.fill", .orange)
    case "education":    return ("book.closed.fill", .blue)
    case "design":       return ("paintpalette.fill", .pink)
    case "productivity": return ("calendar.badge.checkmark", .yellow)
    case "support":      return ("gearshape.fill", .brown)
    case "other":        return ("square.grid.2x2.fill", .gray)
    default:             return ("bubble.left.fill", .gray)
    }
}

/// Folder icon composed from the folder's top member glyphs: a rounded-rect
/// "group" container tinted with the first member's category color, holding up
/// to 3 distinct category symbols. Empty folder → plain gray folder glyph.
/// Pure rendering — the glyph selection/dedup happens in groupedSessionIDs.
/// The "grouped list" glyph from the user-provided asset: two rounded
/// square outlines on the left, four list lines on the right. Traced from
/// the 1024-unit SVG; squares are drawn as even-odd rings so the whole
/// glyph is a single fill (no stroke-vs-fill mixing).
struct GroupGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let u = rect.width / 1024.0

        func ring(x: CGFloat, y: CGFloat) {
            // Outer 325.8×325.8 with r 93; inner inset by the 46.5 stroke.
            let outer = CGRect(x: x * u, y: y * u, width: 325.8 * u, height: 325.8 * u)
            let inner = outer.insetBy(dx: 46.5 * u, dy: 46.5 * u)
            p.addRoundedRect(in: outer, cornerSize: CGSize(width: 93 * u, height: 93 * u), style: .continuous)
            p.addRoundedRect(in: inner, cornerSize: CGSize(width: 46.5 * u, height: 46.5 * u), style: .continuous)
        }
        func line(cy: CGFloat) {
            let r = CGRect(x: 558.5 * u, y: (cy - 23.27) * u, width: 325.8 * u, height: 46.5 * u)
            p.addRoundedRect(in: r, cornerSize: CGSize(width: 23.27 * u, height: 23.27 * u))
        }

        ring(x: 139.6, y: 139.6)
        ring(x: 139.6, y: 511.9)
        line(cy: 209.5)
        line(cy: 395.6)
        line(cy: 581.8)
        line(cy: 768.0)
        return p
    }
}

/// Group icon: the grouped-list glyph on the SAME circular translucent tint
/// the session rows use, at the same 44pt slot — so a group icon and a
/// session icon are the same species at the same size. The tint and glyph
/// color borrow the newest member's category color (gray when empty), which
/// is all that remains of the member-glyph composition: the shape is
/// uniform, the color still says what the group holds.
struct FolderComposedIcon: View {
    let glyphs: [FolderGlyph]
    var diameter: CGFloat = 44

    var body: some View {
        let tint = glyphs.first?.color ?? .gray
        ZStack {
            // 0.28 vs the session icons' 0.18: a deliberately stronger tint
            // so a group circle reads as a different kind of thing at a
            // glance, while keeping the same size and shape language.
            Circle()
                .fill(tint.opacity(0.28))
            GroupGlyphShape()
                .fill(tint, style: FillStyle(eoFill: true))
                .frame(width: diameter * 0.56, height: diameter * 0.56)
        }
        .frame(width: diameter, height: diameter)
    }
}

struct SessionRow: View, Equatable {
    // [T-ios-session-list-equatable-jank] Custom Equatable so `.equatable()` at
    // the call site gates parent-driven re-evaluation on a CHEAP compare of just
    // the fields this row actually renders — instead of SwiftUI deep-comparing
    // the whole `ChatSession` value (the `let session` input). Post the
    // sessionsByIdCache fix, the HangDetector scroll stack still showed
    // AGGraphSetOutputValue → ChatSession.== recursion: it was THIS row's
    // whole-struct input being compared per transaction × visible rows.
    // Comparing only the rendered fields (all short) collapses that to a handful
    // of cheap, short-circuiting comparisons. The @ObservedObject trackers below
    // still drive in-place re-eval on running/lock/font changes (Equatable only
    // gates the parent-push path, not observed-object invalidation).
    static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        lhs.session.id == rhs.session.id
            && lhs.session.title == rhs.session.title
            && lhs.session.lastMessage == rhs.session.lastMessage
            && lhs.session.updatedAt == rhs.session.updatedAt
            && lhs.session.pinnedAt == rhs.session.pinnedAt
            && lhs.session.category == rhs.session.category
            && lhs.session.source == rhs.session.source
            && lhs.session.remoteDeviceId == rhs.session.remoteDeviceId
            && lhs.isHighlighted == rhs.isHighlighted
            && lhs.highlightQuery == rhs.highlightQuery
            && lhs.matchSnippet == rhs.matchSnippet
            && lhs.isActiveOverride == rhs.isActiveOverride
            && lhs.isSuspendedOverride == rhs.isSuspendedOverride
    }

    let session: ChatSession
    var isHighlighted: Bool = false
    var highlightQuery: String? = nil
    /// When set, replaces the generic `lastMessage` preview in the subtitle
    /// slot with this body-extracted snippet (~100 chars around the first
    /// hit). Only populated when the search hit was on message body —
    /// title matches keep the highlighted title in the title slot and fall
    /// back to `lastMessage` below. (T-search-highlight 8edb74f2)
    var matchSnippet: String? = nil
    /// Running / suspended state passed in as VALUES by the sidebar list so a
    /// flip changes this view's value and re-evaluates `body` in place (same
    /// ForEach identity — no cell rebuild / scroll jump). When nil (e.g. the
    /// bare `SessionRow(session:)` call site) we fall back to reading the
    /// observed trackers directly. [T-ios-ipad-sidebar-running-indicator-stale]
    var isActiveOverride: Bool? = nil
    var isSuspendedOverride: Bool? = nil
    @ObservedObject private var activityTracker = SessionActivityTracker.shared
    @ObservedObject private var concurrencyManager = SessionConcurrencyManager.shared
    @ObservedObject private var lockStore = SessionLockStore.shared
    // [T-ios-session-paused-badge] Observe the badge-state queue so a session's
    // "!" paused badge appears/clears in place (same row identity) when the
    // queue changes. The custom Equatable above gates only the parent-push
    // path; @ObservedObject still drives in-place re-eval on store changes.
    @ObservedObject private var badgeStore = SessionBadgeStore.shared
    // Observe App Base font scale so the row re-evaluates when the user moves
    // the slider. The row's fonts use hardcoded `.system(size:)` which ignore
    // Dynamic Type, so we must explicitly multiply by the App Base scale.
    @ObservedObject private var fontSettings = FontSettings.shared

    init(session: ChatSession,
         isHighlighted: Bool = false,
         isActive: Bool? = nil,
         isSuspended: Bool? = nil,
         highlightQuery: String? = nil,
         matchSnippet: String? = nil) {
        self.session = session
        self.isHighlighted = isHighlighted
        self.isActiveOverride = isActive
        self.isSuspendedOverride = isSuspended
        self.highlightQuery = highlightQuery
        self.matchSnippet = matchSnippet
    }

    private var isActive: Bool {
        isActiveOverride ?? activityTracker.isActive(session.id)
    }

    private var isSuspended: Bool {
        isSuspendedOverride ?? concurrencyManager.isSuspended(session.id)
    }

    /// True when the row should render the lock affordance — global
    /// toggle on, biometric supported, this session is in the locked set,
    /// AND the user hasn't unlocked it in the current run. Without the
    /// `isCurrentlyUnlocked` check, an already-unlocked session keeps
    /// rendering its title + last-message line blurred even though the
    /// detail view is freely accessible — the row blur outlived its
    /// purpose for the rest of the session.
    private var isVisuallyLocked: Bool {
        lockStore.isVisuallyLocked(session.id)
    }

    /// The transient badge to render for this row, after suppressing states that
    /// contradict the row's live activity.
    ///
    /// [T-ios-session-running-shows-pause-badge] A session that is actively
    /// running its agent loop (`isActive`, drawn with the SpinningRing) is by
    /// definition NOT paused — yet a transient `canResume=true` flip mid-run
    /// (interrupted-tail detection at load, a Stop case that then resumes, a
    /// background-suspend that's already back in-flight) can leave a stale
    /// `.paused` in the queue. The launch/foreground reconcile already excludes
    /// active sessions; do the same continuously at render so a spinning row can
    /// never also show ⏸. Non-`.paused` queue states are unaffected.
    private var visibleBadge: SessionBadgeState? {
        guard let badge = badgeStore.topCornerBadge(for: session.id) else { return nil }
        if badge == .paused && isActive { return nil }
        return badge
    }

    /// [T-ios-session-unread-badge] Whether to draw the top-trailing red unread
    /// dot — a background task finished and posted its notification, and the user
    /// hasn't opened the session yet. Independent of `visibleBadge` (the
    /// bottom-trailing corner badge), so an unread session can also show ⏸.
    private var showsUnreadDot: Bool {
        guard !isHighlighted else { return false }
        return badgeStore.hasUnread(for: session.id)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Provider icon with optional spinning/suspended ring
            providerIcon
                .frame(width: 44, height: 44)
                .background(iconBackgroundColor.opacity(isHighlighted ? 0.35 : 0.18))
                .clipShape(Circle())
                .overlay {
                    if isSuspended {
                        SuspendedRing(color: .yellow)
                            .frame(width: 42, height: 42)
                    } else if isActive {
                        SpinningRing(color: iconBackgroundColor)
                            .frame(width: 42, height: 42)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Lock badge takes precedence over source / remote
                    // badges: the locked state is the most important
                    // affordance for the user when scanning the list.
                    if isVisuallyLocked {
                        badgeCircle(icon: "lock.fill", color: .gray)
                            .offset(x: 2, y: 2)
                    } else if let badge = visibleBadge {
                        // [T-ios-session-paused-badge] Transient queue states win
                        // over the source / iCloud badges. Head-of-queue is shown.
                        badgeCircle(for: badge)
                            .offset(x: 2, y: 2)
                    } else if session.source == "shortcut" {
                        badgeCircle(icon: "bolt.fill", color: .orange)
                            .offset(x: 2, y: 2)
                    } else if session.isRemote {
                        badgeCircle(icon: "icloud.fill", color: .blue, iconSize: 7)
                            .offset(x: 2, y: 2)
                    }
                }
                // [T-ios-session-unread-badge] Top-trailing red unread dot,
                // independent of the bottom-trailing corner badge above so an
                // unread session can also show ⏸ / iCloud without conflict.
                .overlay(alignment: .topTrailing) {
                    if showsUnreadDot {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .offset(x: -1, y: 1)
                    }
                }

            // Title + subtitle. For locked sessions both lines are blurred
            // so neither the conversation topic nor the last message reads
            // as plain text in the list. The avatar and trailing lock-icon
            // overlay sit outside this VStack so they stay crisp.
            VStack(alignment: .leading, spacing: 4) {
                highlightedText(
                    session.title ?? "New Chat",
                    font: .system(size: fontSettings.scaledApp(16), weight: .semibold),
                    color: Color(UIColor.label)
                )
                .lineLimit(1)

                if let snippet = matchSnippet, !snippet.isEmpty {
                    // During active search, prefer the body-match snippet over
                    // the generic lastMessage preview so the user can see WHY
                    // this session matched. Mirrors Android SessionListScreen
                    // 545d585. The snippet itself is also highlighted so the
                    // keyword stands out inside the ~100-char window.
                    highlightedText(
                        snippet,
                        font: .system(size: fontSettings.scaledApp(14)),
                        color: Color(UIColor.secondaryLabel)
                    )
                    .lineLimit(2)
                } else {
                    highlightedText(
                        session.lastMessage ?? "No messages yet",
                        font: .system(size: fontSettings.scaledApp(14)),
                        color: Color(UIColor.secondaryLabel)
                    )
                    .lineLimit(1)
                }
            }
            // Blur the locked content. Compared to the earlier hard
            // `.clipped()` rectangle, the rounded-rectangle clip + a
            // gentler radius + a soft horizontal fade at the trailing
            // edge let the obfuscated text dissolve into the row
            // background instead of presenting a crisp blurred block.
            //
            // [T-ios16-title-color] The modifier chain (blur+clipShape+mask)
            // is only applied while the session is actually locked. iOS 16's
            // SwiftUI renderer drains color saturation through a stack of
            // even-no-op effect modifiers (mask{Rectangle()} included), which
            // showed up as the session title rendering pale grey on iOS 16
            // while iOS 17+ kept it crisp black. Gating the whole effect
            // chain on the lock flag is the cheapest universal fix.
            .modifier(LockedRowEffect(isLocked: isVisuallyLocked))

            Spacer(minLength: 1)

            VStack(alignment: .trailing, spacing: 4) {
                // Date
                Text(relativeDate(session.updatedAt))
                    .font(.system(size: fontSettings.scaledApp(13)))
                    .foregroundStyle(Color(UIColor.tertiaryLabel))
                if isVisuallyLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(UIColor.tertiaryLabel))
                } else if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(UIColor.tertiaryLabel))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        #if DEBUG
        // TEMPORARY height probe — confirms List self-sizing jitter source.
        // PreferenceKey fires on every real layout (incl. the self-size
        // correction), unlike onAppear which fires once pre-layout.
        .background(GeometryReader { g in
            Color.clear.preference(key: RowHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(RowHeightKey.self) { h in
            probeRowHeight(h, matchSnippet == nil ? "plain" : "snippet")
        }
        #endif
    }

    private func badgeCircle(icon: String, color: Color, iconSize: CGFloat = 9, size: CGFloat = 16) -> some View {
        Image(systemName: icon)
            .font(.system(size: iconSize, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color)
            .clipShape(Circle())
    }

    /// [T-ios-session-paused-badge] Maps a queued badge state to its corner
    /// badge. Reuses the same `badgeCircle` layout/size/position as the iCloud
    /// and lock badges so all session badges sit identically on the icon corner.
    @ViewBuilder
    private func badgeCircle(for state: SessionBadgeState) -> some View {
        switch state {
        case .paused:
            // Pause glyph (⏸), orange to distinguish from the blue iCloud badge.
            badgeCircle(icon: "pause.fill", color: .orange, iconSize: 8)
        case .iCloudSyncing:
            badgeCircle(icon: "icloud.fill", color: .blue, iconSize: 7)
        case .unread:
            // [T-ios-session-unread-badge] `.unread` renders as a separate
            // top-trailing red dot (see the .topTrailing overlay), never through
            // this bottom-trailing corner path. `topCornerBadge` filters it out
            // upstream, so this case is unreachable — render nothing defensively.
            EmptyView()
        }
    }

    @ViewBuilder
    private func highlightedText(_ text: String, font: Font, color: Color) -> some View {
        if let query = highlightQuery, !query.isEmpty,
           SearchKeywords.firstHit(in: text, terms: SearchKeywords.terms(query)) != nil {
            Text(Self.highlightedAttributedString(text: text, query: query, baseColor: color))
                .font(font)
        } else {
            Text(text).font(font).foregroundStyle(color)
        }
    }

    /// Build a SwiftUI `AttributedString` with `backgroundColor` painted on
    /// every case-insensitive occurrence of every keyword of `query`
    /// ([T-search-multi-keyword]: whitespace separates keywords, and a line
    /// holding several has all of them marked). Matches Android
    /// `highlightedAnnotatedString` (commit 545d585) — same theme-aware
    /// tint, same case-insensitive match, same span-style approach.
    /// (T-search-highlight 8edb74f2)
    static func highlightedAttributedString(text: String, query: String, baseColor: Color) -> AttributedString {
        PerfTrace.measure("SessionRow.highlightedAttributedString") {
            highlightedAttributedStringImpl(text: text, query: query, baseColor: baseColor)
        }
    }

    private static func highlightedAttributedStringImpl(text: String, query: String, baseColor: Color) -> AttributedString {
        var attr = AttributedString(text)
        attr.foregroundColor = baseColor
        guard !query.isEmpty else { return attr }
        let highlightBg = Color.accentColor.opacity(0.25)
        let totalChars = text.count
        for range in SearchKeywords.hitRanges(in: text, terms: SearchKeywords.terms(query)) {
            let lo = text.distance(from: text.startIndex, to: range.lowerBound)
            let hi = text.distance(from: text.startIndex, to: range.upperBound)
            // Clamp to attr length; `AttributedString.index(_:offsetByCharacters:)`
            // traps on out-of-range, so we guard up front. AttributedString
            // built from a Swift `String` shares the same character count
            // as `text.count` (grapheme-cluster clusters identical), so a
            // single bounds check is enough.
            guard lo >= 0, hi <= totalChars, lo < hi else { continue }
            let attrLo = attr.index(attr.startIndex, offsetByCharacters: lo)
            let attrHi = attr.index(attr.startIndex, offsetByCharacters: hi)
            let r = attrLo..<attrHi
            attr[r].backgroundColor = highlightBg
            attr[r].foregroundColor = Color.accentColor
            attr[r].inlinePresentationIntent = .stronglyEmphasized
        }
        return attr
    }


    private var categoryIcon: (systemName: String, color: Color) {
        sessionCategoryIcon(for: session.category)
    }

    @ViewBuilder
    private var providerIcon: some View {
        let icon = categoryIcon
        let size: CGFloat = (icon.systemName == "bubble.left.fill" || icon.systemName == "terminal.fill") ? 18 : 20
        Image(systemName: icon.systemName)
            .font(.system(size: size))
            .foregroundStyle(icon.color)
    }

    private var iconBackgroundColor: Color {
        categoryIcon.color
    }

    private func relativeDate(_ date: Date) -> String {
        PerfTrace.measure("SessionRow.relativeDate") {
            Self.relativeDateImpl(date)
        }
    }

    // [T-ios-sessionlist-time-i18n] Row timestamps were hardcoded English
    // ("Yesterday", "N min ago", raw "M/d") while the section headers around
    // them localize via LocalizedStringKey — a zh UI showed "昨天" headers
    // next to "Yesterday" row times. All four phrase keys already exist in
    // Localizable.xcstrings (8 locales); the weekday/short-date fall-backs
    // use localized format templates so e.g. zh renders 7月8日 instead of 7/8.
    // fileprivate (not private): FolderRowHeader shares this exact formatter —
    // a second hand-rolled variant is how the T-ios-sessionlist-time-i18n
    // drift happened the first time.
    static func relativeDateImpl(_ date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        let seconds = Int(now.timeIntervalSince(date))
        if calendar.isDateInToday(date) {
            if seconds < 60 {
                return AppLocalized("Just now")
            } else if seconds < 3600 {
                let mins = seconds / 60
                return AppLocalized("\(mins) min ago")
            } else {
                let hrs = seconds / 3600
                return AppLocalized("\(hrs) hr ago")
            }
        } else if calendar.isDateInYesterday(date) {
            return AppLocalized("Yesterday")
        } else {
            let diff = calendar.dateComponents([.day], from: date, to: now)
            let formatter = DateFormatter()
            if let days = diff.day, days < 7 {
                formatter.setLocalizedDateFormatFromTemplate("EEEE")
            } else {
                formatter.setLocalizedDateFormatFromTemplate("Md")
            }
            return formatter.string(from: date)
        }
    }
}

/// Gate the blur + clip + gradient-mask trio on the lock flag so iOS 16
/// doesn't pay the always-on `.mask { Rectangle() }` color-drain cost
/// for unlocked rows (T-ios16-title-color). When unlocked, the row
/// renders with no extra effect modifiers at all.
/// [T-folder-summary-lock] A group's "N chats · <newest member title>" line.
/// The title is the newest member's, so when that member is Face ID locked it
/// is blurred exactly like the member's own row (`LockedRowEffect`) — it used
/// to read in plain text on the group card and in the Move-to-Group picker,
/// defeating the lock. Observes the lock store so it clears in place on unlock
/// and re-blurs on relock. Locked form: the SAME localized "%lld chats · %@"
/// formatted with an empty title (every locale ends in " · %@", so this is the
/// exact prefix, word order included), then the blurred title beside it.
struct FolderSummaryLine: View {
    let count: Int
    let title: String
    let sessionId: String?
    @ObservedObject private var lockStore = SessionLockStore.shared

    var body: some View {
        if let sessionId, lockStore.isVisuallyLocked(sessionId) {
            let noTitle = ""
            HStack(spacing: 4) {
                Text(verbatim: AppLocalized("\(count) chats · \(noTitle)")
                    .trimmingCharacters(in: .whitespaces))
                Text(verbatim: title)
                    .modifier(LockedRowEffect(isLocked: true))
            }
        } else {
            Text("\(count) chats · \(title)")
        }
    }
}

private struct LockedRowEffect: ViewModifier {
    let isLocked: Bool

    func body(content: Content) -> some View {
        if isLocked {
            content
                .blur(radius: 4)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.82),
                            .init(color: .black.opacity(0.0), location: 1.0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
        } else {
            content
        }
    }
}

/// Row for a session synced from another device, with an iCloud badge on the icon.
struct RemoteSessionRow: View {
    let session: ChatSession

    var body: some View {
        HStack(spacing: 8) {
            // Category icon with iCloud badge
            providerIcon
                .frame(width: 44, height: 44)
                .background(iconColor.opacity(0.18))
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Color.blue)
                        .clipShape(Circle())
                        .offset(x: 2, y: 2)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title ?? "Untitled")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(UIColor.label))
                    .lineLimit(1)
                Text(session.updatedAt, style: .relative)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(UIColor.secondaryLabel))
                    .lineLimit(1)
            }

            Spacer(minLength: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var categoryIcon: (systemName: String, color: Color) {
        sessionCategoryIcon(for: session.category)
    }

    private var iconColor: Color { categoryIcon.color }

    @ViewBuilder
    private var providerIcon: some View {
        let icon = categoryIcon
        let size: CGFloat = (icon.systemName == "bubble.left.fill" || icon.systemName == "terminal.fill") ? 18 : 20
        Image(systemName: icon.systemName)
            .font(.system(size: size))
            .foregroundStyle(icon.color)
    }
}

/// A dashed circle ring indicating a session is suspended (waiting for a concurrency slot).
private struct SuspendedRing: View {
    let color: Color

    var body: some View {
        Circle()
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
    }
}
