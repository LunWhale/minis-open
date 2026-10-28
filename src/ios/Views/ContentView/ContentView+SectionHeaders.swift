//
//  ContentView+SectionHeaders.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  ContentView, section headers: the multi-select row, date and folder section
//  headers (folder card, collapse, menu), folder picker items, and folder
//  actions (new chat in a folder, delete a folder with its sessions).
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

extension ContentView {
    // MARK: - Selectable Row

    func selectableRow(_ session: ChatSession) -> some View {
        Button {
            if selectedIds.contains(session.id) {
                selectedIds.remove(session.id)
            } else {
                selectedIds.insert(session.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedIds.contains(session.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selectedIds.contains(session.id) ? Color.accentColor : Color(UIColor.tertiaryLabel))
                SessionRow(session: session)
            }
            .padding(.leading, 16)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section Header

    @ViewBuilder
    func sectionHeader(index: Int, group: SidebarGroup) -> some View {
        if isSelecting {
            let groupIds = Set(group.ids)
            let allSelected = !groupIds.isEmpty && groupIds.isSubset(of: selectedIds)
            Button {
                if allSelected {
                    selectedIds.subtract(groupIds)
                } else {
                    selectedIds.formUnion(groupIds)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(allSelected ? Color.accentColor : Color(UIColor.tertiaryLabel))
                    // group.label is a stable English key (used for logic like
                    // == "Pinned"); localize only at display via LocalizedStringKey.
                    // Folder names are user data — render verbatim, not as a key.
                    if group.folderId != nil {
                        Text(group.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(UIColor.secondaryLabel))
                    } else {
                        Text(LocalizedStringKey(group.label))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(UIColor.secondaryLabel))
                    }
                }
                .textCase(nil)
            }
            .buttonStyle(.plain)
        } else if index > 0 || group.label == "Pinned" {
            HStack(spacing: 4) {
                if group.label == "Pinned" {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(UIColor.secondaryLabel))
                }
                // group.label stays an English key for logic; LocalizedStringKey
                // resolves the display string per system language.
                Text(LocalizedStringKey(group.label))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(UIColor.secondaryLabel))
            }
            .textCase(nil)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(dropTargetFolderId == "" ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            // Dropping on a date-bucket header moves the sessions OUT of any
            // folder — the drag gesture works both directions, otherwise
            // moving out would still require a trip through the menu.
            .dropDestination(for: String.self) { sessionIds, _ in
                Task { @MainActor in
                    await ChatStore.shared.setFolder(nil, forSessions: sessionIds)
                    refreshSessionList()
                }
                return true
            } isTargeted: { over in
                if over {
                    dropTargetFolderId = ""
                } else if dropTargetFolderId == "" {
                    dropTargetFolderId = nil
                }
            }
        }
    }

    /// Display aggregates for the Move-to-Group picker rows: the same
    /// composed icon glyphs and member count the home group card shows, plus
    /// the subtitle context — the folder's description when one is set,
    /// otherwise the newest member's title (mirroring the card's summary).
    /// Computed once per sheet presentation, not per row.
    ///
    /// [T-folder-picker-recency] Ordered most recently active first
    /// (`FolderPickerOrder`), so the group a session most likely belongs in is
    /// at the top. Only this picker is reordered; the home list keeps its own
    /// group order.
    func folderPickerItems() -> [FolderPickerSheet.FolderItem] {
        let byFolder = Dictionary(grouping: sessions.filter { $0.folderId != nil },
                                  by: { $0.folderId! })
        var activity: [String: Date] = [:]
        let items = folders.map { folder in
            let m = (byFolder[folder.id] ?? []).sorted { $0.updatedAt > $1.updatedAt }
            activity[folder.id] = FolderPickerOrder.lastActive(
                folderUpdatedAt: folder.updatedAt, folderCreatedAt: folder.createdAt,
                newestMemberUpdatedAt: m.first?.updatedAt)
            // Top-3 DISTINCT category glyphs by recency — same rule as
            // groupedSessionIDs, so the picker icon matches the home card.
            var glyphs: [FolderGlyph] = []
            var seenCategories = Set<String>()
            for s in m where seenCategories.insert(s.category ?? "").inserted {
                let icon = sessionCategoryIcon(for: s.category)
                glyphs.append(FolderGlyph(systemName: icon.systemName, color: icon.color))
                if glyphs.count == 3 { break }
            }
            let desc = folder.desc?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return FolderPickerSheet.FolderItem(
                folder: folder,
                glyphs: glyphs,
                count: m.count,
                subtitle: desc.isEmpty ? m.first?.title : desc,
                subtitleSessionId: desc.isEmpty ? m.first?.id : nil)
        }
        return FolderPickerOrder.byRecentActivity(items) { activity[$0.folder.id] ?? .distantPast }
    }

    /// Folder section header: composed icon + name + count + collapse chevron,
    /// with the collapsed-state status passthrough (running / paused / unread).
    ///
    /// The status badges appear ONLY when collapsed: expanded members carry
    /// their own indicators, and duplicating them in the header would leave
    /// the user guessing which row a header "!" refers to. Collapsing is what
    /// hides the members' state — that's exactly when a proxy is needed.
    /// Folder card mirroring SessionRow's frame — same 44pt icon circle, same
    /// title/subtitle stack, same trailing date column — so a folder reads as
    /// the same species of thing as a session. Only the content differs:
    /// composed member-glyph icon, folder name, and a "N chats · latest
    /// title" summary where a session shows its last message.
    /// `scrollProxy` is forwarded to `toggleFolderCollapsed` so an expand can
    /// re-anchor this header after the accordion removes the previously-open
    /// folder's rows ([T-ios-folder-accordion-scroll-anchor]).
    func folderSectionHeader(_ group: SidebarGroup, scrollProxy: ScrollViewProxy? = nil) -> some View {
        // Content + onTapGesture instead of a Button: the Button's own
        // long-press handling raced the contextMenu recognizer on some
        // platforms (long-press on the card did not reliably pop the menu).
        // With a bare tap gesture the long-press belongs to the contextMenu
        // alone; the accessibility action keeps the card activatable for
        // AX clients and the debug tap harness.
        HStack(spacing: 8) {
                FolderComposedIcon(glyphs: group.glyphs)
                    // Same overlay corners as SessionRow: spinner ring for
                    // running, bottom-trailing badge for paused, top-trailing
                    // red dot for unread — the symbols the user already knows
                    // from session rows, in the positions they know them.
                    // Collapsed-only: expanded members carry their own
                    // indicators, and a header copy would leave the user
                    // guessing which row it refers to.
                    .overlay {
                        if group.isCollapsed && group.anyActive {
                            SpinningRing(color: group.glyphs.first?.color ?? .gray)
                                .frame(width: 42, height: 42)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if group.isCollapsed && group.anyPaused {
                            ZStack {
                                Circle().fill(Color(UIColor.systemBackground))
                                    .frame(width: 16, height: 16)
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.orange)
                            }
                            .offset(x: 2, y: 2)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if group.isCollapsed && group.anyUnread {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .offset(x: -1, y: 1)
                        }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    // Folder names are user data — verbatim Text, never a
                    // LocalizedStringKey lookup.
                    // [T-search-folder-expand] A folder-name hit is highlighted
                    // like a title hit on a session row.
                    Group {
                        if searchResultsActive,
                           SearchKeywords.firstHit(in: group.label, terms: SearchKeywords.terms(searchQuery)) != nil {
                            Text(SessionRow.highlightedAttributedString(
                                text: group.label, query: searchQuery, baseColor: Color(UIColor.label)))
                        } else {
                            Text(group.label).foregroundStyle(Color(UIColor.label))
                        }
                    }
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Group {
                        if searchResultsActive {
                            // In a result set the members are the matches.
                            Text("\(group.totalCount) matching chats")
                        } else if let title = group.summaryTitle {
                            FolderSummaryLine(count: group.totalCount, title: title,
                                              sessionId: group.summarySessionId)
                        } else if group.totalCount > 0 {
                            Text("\(group.totalCount) chats")
                        } else {
                            Text("Empty group")
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Color(UIColor.secondaryLabel))
                    .lineLimit(1)
                }

                Spacer(minLength: 1)

                VStack(alignment: .trailing, spacing: 6) {
                    if let date = group.latestDate {
                        Text(SessionRow.relativeDateImpl(date))
                            .font(.system(size: 13))
                            .foregroundStyle(Color(UIColor.tertiaryLabel))
                    }
                    HStack(spacing: 4) {
                        if group.isFolderPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(UIColor.tertiaryLabel))
                        }
                        // [T-search-folder-expand] No fold chevron in a result
                        // set: folders stay open there, so it would do nothing.
                        if !searchResultsActive {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(UIColor.tertiaryLabel))
                                .rotationEffect(.degrees(group.isCollapsed ? -90 : 0))
                        }
                    }
                }
            }
            // Inner 10 + outer 6 = 16pt — the same lead as SessionRow's
            // horizontal padding, so the folder icon's left edge and (via the
            // shared 44pt icon frame + 8pt spacing) the folder TITLE both sit
            // exactly on the session rows' alignment grid.
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .textCase(nil)
            .contentShape(Rectangle())
            // Mini-bar trigger: only an EXPANDED, populated group needs its
            // header tracked (a collapsed card scrolling away is just a card).
            .background {
                if let fid = group.folderId, !group.isCollapsed, !group.ids.isEmpty {
                    FolderHeaderVisibilityProbe(
                        folderId: fid,
                        thresholdY: folderMiniBarTopY,
                        onVisibilityChange: setFolderHeaderOffscreen)
                }
            }
            .modifier(FolderCardBackground(
                isDropTarget: dropTargetFolderId == group.folderId,
                isExpanded: !group.isCollapsed && !group.ids.isEmpty))
            // Outer insets float the rounded card inside the list width —
            // the inset frame is what separates it from the full-bleed
            // session rows at a glance. (The glass/pre-26 card is what the
            // pinned header shows while its members scroll under; rows
            // passing through the 12pt gutters is the standard floating-
            // header look, not the ghosting the old opaque background fixed.)
            // 6pt matches the splitList selection highlight's horizontal
            // inset, so the folder container and a selected member row share
            // the same left/right edges instead of the container overhanging.
            .padding(.horizontal, 6)
            .padding(.top, 4)
            // Expanded: no bottom gap — the card welds onto the first member
            // row's container segment.
            .padding(.bottom, (group.isCollapsed || group.ids.isEmpty) ? 4 : 0)
        .onTapGesture {
            if let fid = group.folderId { toggleFolderCollapsed(fid, scrollProxy: scrollProxy) }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if let fid = group.folderId { toggleFolderCollapsed(fid, scrollProxy: scrollProxy) }
        }
        // [T-ios-folder-accordion-scroll-anchor] Record this header's on-screen
        // position so the accordion can decide whether a scroll correction is
        // needed. Unlike FolderHeaderVisibilityProbe (mini-bar, expanded folders
        // only) this tracks EVERY header including collapsed ones — the folder
        // about to be expanded is collapsed at the moment of the tap, so its
        // pre-toggle position is exactly what has to be known.
        //
        // A background GeometryReader: it reads the row's own frame without
        // participating in its layout, so no sizing behaviour changes.
        .background {
            if let fid = group.folderId {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { folderHeaderTopY[fid] = geo.frame(in: .global).minY }
                        .onChange(of: geo.frame(in: .global).minY) { folderHeaderTopY[fid] = $0 }
                }
            }
        }
        // ScrollViewReader anchor for the mini-bar's "back to header" jump.
        .id("folderHeader-\(group.folderId ?? "")")
        .listRowInsets(EdgeInsets())
        .dropDestination(for: String.self) { sessionIds, _ in
            guard let fid = group.folderId else { return false }
            Task { @MainActor in
                await ChatStore.shared.setFolder(fid, forSessions: sessionIds)
                refreshSessionList()
            }
            return true
        } isTargeted: { over in
            if over {
                dropTargetFolderId = group.folderId
            } else if dropTargetFolderId == group.folderId {
                dropTargetFolderId = nil
            }
        }
        .contextMenu {
            if let fid = group.folderId, let folder = folders.first(where: { $0.id == fid }) {
                Button {
                    Task { @MainActor in
                        await ChatStore.shared.toggleFolderPin(fid)
                        refreshSessionList()
                    }
                } label: {
                    Label(LocalizedStringKey(folder.isPinned ? "Unpin" : "Pin"),
                          systemImage: folder.isPinned ? "pin.slash" : "pin")
                }
                Button {
                    renameFolderText = folder.name
                    // [T-folder-rename-desc-wipe] Seed the description too.
                    // Both fields are shared @State that outlive the dialog, and
                    // `onRename` ALWAYS passes the desc field through (empty
                    // clears the stored value, by design). Leaving this unseeded
                    // meant the field opened blank — or holding whatever was
                    // typed for a previously renamed folder — so a rename that
                    // only touched the NAME silently wiped that folder's
                    // description. Repeat across folders and every description
                    // disappears, which reads as "renaming one group overwrote
                    // them all".
                    renameFolderDesc = folder.desc ?? ""
                    folderToRename = folder
                } label: {
                    Label("Rename Group", systemImage: "square.and.pencil")
                }
                Button {
                    newChatInFolder(fid)
                } label: {
                    Label("New Chat in Group", systemImage: "plus.bubble")
                }
                Divider()
                // Dissolve is deliberately NOT destructive-tinted: it touches
                // no user data (sessions move back to the main list). Tinting
                // it red would train the eye to read it as the deleting item.
                Button {
                    folderToDissolve = folder
                } label: {
                    Label("Dissolve Group", systemImage: "folder.badge.minus")
                }
                Divider()
                // The one destructive item, last, with the count in the title
                // so the consequence is visible in the menu itself, not only
                // in the confirmation sheet.
                Button(role: .destructive) {
                    requestDeleteFolderWithSessions(folder)
                } label: {
                    Label("Delete Group & \(group.totalCount) Sessions", systemImage: "trash")
                }
            }
        }
    }

    /// "New chat in folder": file the just-promoted draft. Separate from the
    /// draft-bookkeeping onReceive (which is gated on isWideLayout) because
    /// this must run on iPhone too. The notification can arrive off-main
    /// (ChatStore actor executor) — all state access happens inside the
    /// MainActor hop. Extracted to a method so the body's modifier chain
    /// stays type-checkable.
    func handleSessionCreatedForPendingFolder(_ note: Notification) {
        guard let newId = note.object as? String else { return }
        let noteDraftId = (note.userInfo as? [String: String])?["draftId"]
        Task { @MainActor in
            guard let pending = pendingFolderDraft else { return }
            guard noteDraftId == pending.draftId else {
                // Some other draft was promoted — ours was abandoned. Drop the
                // intent so it can never mis-file a later unrelated chat.
                if noteDraftId != nil { pendingFolderDraft = nil }
                return
            }
            pendingFolderDraft = nil
            _ = await ChatStore.shared.setFolderIfUnfiled(pending.folderId, forSession: newId)
            refreshSessionList()
        }
    }

    /// Folder-header menu: start a new chat that lands inside the folder.
    /// The folder assignment is deferred to draft promotion (see
    /// pendingFolderDraft); the folder is auto-expanded so the new session
    /// doesn't appear to vanish into a collapsed section.
    private func newChatInFolder(_ folderId: String) {
        if collapsedFolderIds.contains(folderId) { toggleFolderCollapsed(folderId) }
        let draftId = Self.makeNewSessionId()
        pendingFolderDraft = (draftId: draftId, folderId: folderId)
        // [T-nav-ghost-row-link] From the home list: replace, never append.
        switchToSession(draftId)
    }

    /// Folder-header menu: delete the folder AND every member session. Reuses
    /// the multi-select delete chain (computeDeleteInfo → DeleteConfirmSheet →
    /// deleteSelectedSessions) rather than a bespoke path — the delete chain
    /// owns session files, tombstones and sync, and re-implementing it would
    /// mean re-earning its correctness.
    private func requestDeleteFolderWithSessions(_ folder: ChatFolder) {
        let memberIds = Set(sessions.filter { $0.folderId == folder.id }.map(\.id))
        selectedIds = memberIds
        pendingDeleteFolderId = folder.id
        deleteInfo = nil
        isComputingDelete = true
        showDeleteConfirm = true
        Task { @MainActor in
            let info = await Self.computeDeleteInfoExpanded(for: memberIds)
            deleteInfo = info
            isComputingDelete = false
        }
    }
}
