//
//  MessageListV3SheetPresenters.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Sheets presented outside the cell tree: ToolSheetPresenter (tool detail),
//  CompactSummaryPresenter, and the transparent SheetOverlayView hosted on
//  MessageListViewController by +Setup.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

// MARK: - Tool Detail Sheet Presenter

/// Holds the state for the tool detail sheet, presented from a transparent overlay
/// on MessageListViewController — outside the UIHostingConfiguration cell tree.
/// This avoids the cell's `.transaction { disablesAnimations = true }` which would
/// suppress the sheet's slide-up animation, and prevents the double-present crash
/// caused by multiple cell bindings re-evaluating on shared state changes.
final class ToolSheetPresenter: ObservableObject {
    struct SheetData: Identifiable {
        let id: UUID
        let block: AssistantBlock
        let toolBlocks: [AssistantBlock]
        let toolSnapshots: [ToolSnapshotItem]
        let browserPool: BrowserTabPool?
    }

    @Published var sheetData: SheetData?
    var onDismiss: (() -> Void)?
    var onBrowserTakeover: (() -> Void)?
    var onTakeoverDone: (() -> Void)?
}

// MARK: - Compact Summary Sheet Presenter

/// Same overlay pattern as ToolSheetPresenter — presents the compact summary
/// sheet outside the cell tree so `.transaction { disablesAnimations }` does
/// not suppress the sheet's slide-up animation.
final class CompactSummaryPresenter: ObservableObject {
    @Published var summary: String?
    /// Forwarded into CompactSummarySheet so its "Revert Compact" button can
    /// invoke the view-model's revertCompact() without the sheet importing it.
    var onRevert: (() -> Void)?
}

/// Transparent SwiftUI view that owns the .sheet() modifier.
/// Installed as a child UIHostingController on MessageListViewController,
/// outside any UIHostingConfiguration cell tree.
struct SheetOverlayView: View {
    @ObservedObject var toolPresenter: ToolSheetPresenter
    @ObservedObject var compactPresenter: CompactSummaryPresenter

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            // [T-agent-transcript-navbar-lost] This host is a child VC inside
            // whatever navigation controller contains the message list, so
            // SwiftUI bridges ITS navigation-bar state to that controller. Its
            // root has no title and no toolbar, so that state computes as
            // "automatic -> hidden", and it is re-applied on presentation
            // events -- i.e. exactly when the tool sheet dismisses. When the
            // containing page is a NavigationStack ROOT (the agent transcript
            // page) that hides the page's bar for good. Pin visible so the
            // bridged state can never be "hidden"; a no-op where the bar is
            // already shown.
            .toolbar(.visible, for: .navigationBar)
            .sheet(item: $toolPresenter.sheetData) { data in
                // [T-agent-tool-sheet-unified] Every tool block — the agent
                // block included — opens the same live sheet (this is the
                // path a tap in the collection view actually takes), with
                // human takeover wired through.
                ToolLiveSheet(
                    toolBlocks: data.toolBlocks,
                    initialIdx: data.toolBlocks.firstIndex(where: { $0.id == data.block.id }) ?? 0,
                    toolSnapshots: data.toolSnapshots,
                    browserPool: data.browserPool,
                    onBrowserTakeover: toolPresenter.onBrowserTakeover,
                    onTakeoverDone: toolPresenter.onTakeoverDone
                )
            }
            .onChange(of: toolPresenter.sheetData?.id) { newVal in
                if newVal == nil {
                    toolPresenter.onDismiss?()
                }
            }
            .sheet(isPresented: Binding(
                get: { compactPresenter.summary != nil },
                set: { if !$0 { compactPresenter.summary = nil } }
            )) {
                CompactSummarySheet(
                    summary: compactPresenter.summary ?? "",
                    onRevert: compactPresenter.onRevert
                )
            }
    }
}
