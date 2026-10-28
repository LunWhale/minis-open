//
//  ContentView+SidebarToolbar.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  ContentView, sidebar toolbar: toolbar items (new chat, tools, settings,
//  terminal, alarms), the navigation-title sync indicator and the migration /
//  sync subtitle with its self-cancelling refresh loop.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

extension ContentView {
    // MARK: - Sidebar Toolbar

    /// Refresh cadence for the sidebar migration subtitle, in seconds.
    private static let migrationSubtitleRefreshInterval: UInt64 = 5

    /// [T-ios-migration-timer-sessionlist-uaf-crash] Self-cancelling refresh loop
    /// for `migrationSubtitle`, driven by `.task` on the identity-stable sidebar
    /// Group. Replaces the process-lived `Timer.publish().autoconnect()` +
    /// `.onReceive` that AttributeGraph could tear down mid-transaction (UAF).
    ///
    /// SwiftUI cancels this Task when the Group's identity ends, so the loop stops
    /// cleanly with no dangling subscription. It parks (no refresh, cheap poll)
    /// while the app is backgrounded — the crash reproduced with the app in the
    /// background, and a hidden sidebar has nothing to display anyway.
    @MainActor
    func migrationSubtitleLoop() async {
        // Mirror the old `.onAppear { refreshMigrationSubtitle() }`: refresh once
        // immediately so the subtitle is correct as soon as the sidebar appears.
        refreshMigrationSubtitle()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.migrationSubtitleRefreshInterval * 1_000_000_000)
            } catch {
                return  // cancelled during sleep
            }
            // Skip the refresh while backgrounded; keep looping so it resumes on
            // return to foreground without needing a separate scene-phase wake.
            // Read the process-level flag (kept current by the scenePhase observer)
            // rather than the `@Environment(\.scenePhase)` captured in this `.task`
            // closure's `self` snapshot, which would be stale.
            let backgrounded: Bool
            if #available(iOS 17.0, *) {
                backgrounded = SyncCore.shared.isAppInBackground
            } else {
                backgrounded = false
            }
            if !backgrounded {
                refreshMigrationSubtitle()
            }
        }
    }

    private func refreshMigrationSubtitle() {
        guard #available(iOS 17.0, *), SyncV2Bootstrap.isEnabled else {
            if migrationSubtitle != nil { migrationSubtitle = nil }
            return
        }
        Task { @MainActor in
            // Engine reports paused first regardless of dirty queue.
            if SyncCore.shared.pausedUntil != nil {
                if migrationSubtitle != .paused { migrationSubtitle = .paused }
                return
            }
            let counts = await ChatStore.shared.countDirtyRecords()
            let byType = Self.formatV2DirtyByType(counts.byType)
            let engineUp = SyncCore.shared.isRunning
            // Engine down but dirty queue is non-empty → stalled, not
            // syncing. The rotating icon would lie about progress.
            if !engineUp, !byType.isEmpty {
                if migrationSubtitle != .waiting { migrationSubtitle = .waiting }
                return
            }
            if let summary = await MigrationEngine.shared.progressSummary() {
                let pct = summary.pushTotal > 0 ? Int(Double(summary.pushDone) * 100.0 / Double(summary.pushTotal)) : 0
                let next: SyncSubtitleState = engineUp
                    ? .migrating(percent: pct, byType: byType)
                    : .waiting
                if migrationSubtitle != next { migrationSubtitle = next }
                return
            }
            if !byType.isEmpty {
                let next: SyncSubtitleState = engineUp ? .syncing(byType: byType) : .waiting
                if migrationSubtitle != next { migrationSubtitle = next }
            } else {
                // No active sync work — hide the subtitle entirely so the
                // "Minis" title sits at its normal size.
                if migrationSubtitle != nil { migrationSubtitle = nil }
            }
        }
    }

    /// Map v2 dirty-by-type counts → display capsules. Only types with
    /// dirty>0 are returned, sorted by count desc, top 3.
    private static func formatV2DirtyByType(_ byType: [String: Int]) -> [(label: String, count: Int)] {
        let labels: [String: String] = [
            "SessionV2": "Ses",
            "MessageV2": "Msg",
            "SessionFileV2": "Fil",
            "CompactMarkerV2": "Cmp",
            "ProviderConfigV2": "Prv",
            "EnvVarV2": "Env",
            "SyncDeviceV2": "Dev",
            "SkillV2": "Skl",
        ]
        return byType
            .compactMap { (k, v) -> (String, Int)? in
                guard v > 0, let label = labels[k] else { return nil }
                return (label, v)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { (label: $0.0, count: $0.1) }
    }

    /// Tiny indicator next to the "Minis" title showing the sync state.
    @ViewBuilder
    private func titleSyncIndicator(for state: SyncSubtitleState?) -> some View {
        switch state {
        case .none, .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
        case .paused:
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
        case .migrating, .syncing:
            PulseRotateIcon()
        case .waiting:
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func syncSubtitleView(_ state: SyncSubtitleState) -> some View {
        HStack(spacing: 5) {
            switch state {
            case .paused:
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Sync paused")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .migrating(let pct, let byType):
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(pct)%")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                ForEach(byType.indices, id: \.self) { i in
                    syncTypeChip(label: byType[i].label, count: byType[i].count)
                }
            case .syncing(let byType):
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(byType.indices, id: \.self) { i in
                    syncTypeChip(label: byType[i].label, count: byType[i].count)
                }
            case .upToDate:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.green)
                Text("Up to date")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .waiting:
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Waiting")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func syncTypeChip(label: String, count: Int) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(formatCompact(count))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Compact integer formatting: 89,401 → "89k", 1,234 → "1.2k", 740 → "740".
    private func formatCompact(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 10_000 {
            let v = Double(n) / 1000.0
            return String(format: "%.1fk", v)
        }
        return "\(n / 1000)k"
    }

    /// The toolbar's terminal icon, pre-scaled to 24pt.
    ///
    /// The asset is a 200x200 bitmap; handing `Image("TerminalCircle")` straight
    /// to the toolbar makes UIKit build the bar button at its 200pt intrinsic
    /// size (see the note at the label). Rendering it to a 24pt UIImage with
    /// UIGraphicsImageRenderer makes the intrinsic size correct at the source,
    /// so it is the same whether it goes through SwiftUI layout or the
    /// UIBarButtonItem bridge. `alwaysTemplate` preserves the asset's template
    /// rendering intent so it still follows the toolbar tint.
    private static let terminalCircleIcon: UIImage = {
        let side: CGFloat = 24
        guard let source = UIImage(named: "TerminalCircle") else {
            return UIImage()
        }
        let size = CGSize(width: side, height: side)
        let scaled = UIGraphicsImageRenderer(size: size).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        return scaled.withRenderingMode(.alwaysTemplate)
    }()

    @ToolbarContentBuilder
    var sidebarToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if isSelecting {
                // [T-ios-ipad-sidebar-title-offcentre] Same width claim as the
                // idle title below — this label is LONGER ("Select Sessions"
                // vs a short SOUL name) and shares the bar with Cancel and
                // Select All, so the narrow sidebar column squeezes it harder.
                Text(selectedIds.isEmpty ? "Select Sessions" : "\(selectedIds.count) Selected")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                let canOpenSync: Bool = {
                    if #available(iOS 17.0, *) { return SyncV2Bootstrap.isEnabled }
                    return false
                }()
                // Title text comes from SOUL.md (falls back to "Minis"). The
                // leading sync indicator floats as an overlay so it doesn't
                // take layout space — title stays perfectly centered in the
                // navigation bar regardless of whether the indicator is visible.
                // When iCloud sync isn't enabled the title is a plain Text;
                // wrapping it in a `.disabled` Button would drain SwiftUI's
                // default disabled-button tint into the label and render the
                // SOUL name grey, which read as a styling bug rather than the
                // intended "no sync detail to open" state.
                // [T-ios-soul-name-sidebar-stale] The `.onReceive(soulMdChanged)`
                // that refreshes `soulName` used to live HERE. It was moved to the
                // stable `sessionList(useNavigationLinks:)` body for the SAME reason
                // the migration timer was (see the T-ios-migration-timer note below):
                // this toolbar principal item rebuilds on every canOpenSync /
                // soulName / migrationSubtitle / isSelecting change, so a sink
                // attached here gets torn down and re-created constantly and can
                // drop a .soulMdChanged notification that arrives during the gap.
                // This Text now only READS `soulName`.
                let titleLabel = Text(soulName)
                    .font(.system(size: 18.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    // A custom SOUL name can be long, and the width claim below
                    // hands this label the whole column — without a limit a long
                    // name would wrap to two lines inside an inline bar or push
                    // under the buttons. One line, shrink a little, then ellipse.
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .overlay(alignment: .leading) {
                        if canOpenSync {
                            Button {
                                activeToolSheet = .syncMigrationDetail
                            } label: {
                                titleSyncIndicator(for: migrationSubtitle)
                                    .contentShape(Rectangle())
                                    .padding(4)
                            }
                            .buttonStyle(.plain)
                            .offset(x: -27)
                        }
                    }
                // [T-ios-migration-timer-toolbar-uaf-crash] The migration-subtitle
                // refresh driver used to live HERE, on this `titleLabel` Text inside
                // the churny toolbar principal item. That item rebuilds whenever
                // canOpenSync / soulName / migrationSubtitle / isSelecting change, so
                // AttributeGraph repeatedly tore down the driver's sink — a
                // use-after-free release in the setBody transaction (EXC_BAD_ACCESS,
                // build 309). The driver now lives on the stable
                // `sessionList(useNavigationLinks:)` body (identity-stable across the
                // sidebar lifetime) as a `.task` async loop, not a Combine timer sink
                // (see migrationSubtitleLoop, T-ios-migration-timer-sessionlist-uaf-crash);
                // this Text only READS the `migrationSubtitle` @State.

                // [T-ios-ipad-sidebar-title-offcentre] Claim the width the bar
                // will give us and centre inside it, instead of letting the
                // item collapse to the title's intrinsic size.
                //
                // Why this is needed on iPad mini portrait specifically: at
                // 744pt the window clears `compactThreshold` (700), so the app
                // uses `splitLayout`. A NavigationSplitView lays each column's
                // bar out independently, so the principal item is centred
                // within the SIDEBAR column — 340pt at its minimum — not the
                // window. That column also carries the gear (leading) plus the
                // alarm and terminal-menu buttons (trailing), roughly 150pt of
                // chrome once margins are counted. UIKit resolves the squeeze
                // by yielding the centre and pinning the shrunken principal
                // item toward the leading side, which is the "title pushed to
                // the left" the report describes.
                //
                // `maxWidth: .infinity` makes the item take the space the bar
                // offers rather than only its text width, so `.center` then has
                // something to centre within; the title sits mid-column and the
                // sync dot keeps riding it as a zero-layout overlay. On wider
                // columns (iPad landscape, larger iPads) this is a no-op — the
                // item was already getting its full width there.
                Group {
                    if canOpenSync {
                        Button {
                            activeToolSheet = .syncMigrationDetail
                        } label: {
                            titleLabel
                        }
                        .buttonStyle(.plain)
                    } else {
                        titleLabel
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            if isSelecting {
                Button("Cancel") {
                    isSelecting = false
                    selectedIds.removeAll()
                }
            } else {
                Button {
                    activeToolSheet = .settings
                } label: {
                    Image(systemName: "gear")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSelecting {
                Button(selectedIds.count == sessions.count ? "Deselect All" : "Select All") {
                    if selectedIds.count == sessions.count {
                        selectedIds.removeAll()
                    } else {
                        selectedIds = Set(sessions.map(\.id))
                    }
                }
            } else if hasAlarms {
                Button {
                    showAlarmList = true
                } label: {
                    Image(systemName: "alarm")
                        .font(.system(size: 15, weight: .medium))
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !isSelecting {
                Menu {
                    Button {
                        showTerminal = true
                    } label: {
                        Label("Shell Terminal", systemImage: "terminal")
                    }
                    Button {
                        activeToolSheet = .rootfsManagement
                    } label: {
                        Label("Rootfs Management", systemImage: "externaldrive")
                    }
                    Divider()
                    Button {
                        activeToolSheet = .browser
                    } label: {
                        Label("Open Browser", systemImage: "globe")
                    }
                    Button {
                        activeToolSheet = .browserManagement
                    } label: {
                        Label("Browser Settings", systemImage: "globe.badge.chevron.backward")
                    }
                    #if DEBUG
                    Divider()
                    // [debug] Keep Screen Awake — disables auto-lock while the app
                    // is foregrounded. Tap toggles; a checkmark shows the current
                    // state. Memory-only (not persisted). DEBUG builds only.
                    Button {
                        keepScreenAwake.toggle()
                        IdleTimerLease.set(.debugMenu, held: keepScreenAwake, reason: "debug menu")
                    } label: {
                        Label("Keep Screen Awake", systemImage: keepScreenAwake ? "checkmark.circle.fill" : "sun.max")
                    }
                    #endif
                } label: {
                    // [T-ios-mac-toolbar-image-intrinsic] TerminalCircle is a
                    // 200x200 bitmap. SwiftUI's `.frame` only constrains the
                    // SwiftUI view; when this label is bridged to a
                    // UIBarButtonItem (Mac / iPad navigation bar) UIKit builds
                    // the button from the IMAGE's intrinsic size, so it came out
                    // 200pt wide and squeezed the `.principal` title down to
                    // 60pt (measured on a 416pt sidebar navbar: gear 44 + this
                    // item 212 + sidebar toggle 44, leaving 60 for the title,
                    // which truncated the SOUL name to "Minif..."). Every other
                    // toolbar item uses an SF Symbol, whose intrinsic size is
                    // already correct — which is why only this one broke.
                    // A pre-scaled UIImage makes the intrinsic size 24pt at the
                    // source, independent of SwiftUI layout.
                    Image(uiImage: Self.terminalCircleIcon)
                }
            }
        }
    }
}
