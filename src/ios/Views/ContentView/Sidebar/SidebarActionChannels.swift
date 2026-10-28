//
//  SidebarActionChannels.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  Action channels between closure-free row / FAB views and ContentView.
//
//  SessionContextMenu and DraggableFAB hold a class reference instead of a
//  closure that captures the ContentView struct - the fix for the context-menu
//  and FAB use-after-free crashes. ContentView+SessionMenu.swift connects the
//  channels to ContentView's methods.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

// MARK: - Session context-menu action channel

/// [T-ios-crash-contextmenu-uaf] Action relay for the sidebar session context
/// menu. Stored as @State in ContentView (stable lifetime); the concrete
/// SessionContextMenu view holds a reference to it but Equatable ignores it,
/// so SwiftUI's attribute-graph copy/release of the view struct only
/// retains/releases this single class reference — no closure captures that
/// could dangle.
@MainActor
final class SessionMenuActionChannel {
    var handler: ((SessionMenuAction) -> Void)?
    func send(_ action: SessionMenuAction) { handler?(action) }
}

/// [T-ios-crash-objectdestroy-fab-uaf] Action relay for the draggable FABs,
/// mirroring SessionMenuActionChannel above and for the same reason.
///
/// `DraggableFAB` stores an `onTap` closure, and both call sites' closures
/// capture `self` (`openSession`, `fabDidDrag`, `showSearchBar`, …). That drags
/// a whole ContentView copy into a heap closure context; when SwiftUI's graph
/// teardown releases it, the stale copy is destroyed field-by-field after its
/// `@State` boxes are already gone — the `objectdestroy.NNTm` use-after-free.
///
/// Routing the action through a class with a stable lifetime means the stored
/// closure captures only this one reference, never the view struct.
@MainActor
final class FABActionChannel {
    enum Action { case newChat, newChatInGroup(String), openSearch }
    var handler: ((Action) -> Void)?
    func send(_ action: Action) { handler?(action) }
}

enum SessionMenuAction {
    /// [T-nav-ghost-row-link] A tap on an iPhone home-list row: open that
    /// session as the only page on the stack (see SessionStackRow).
    case open(String)
    case togglePin(String)
    case exportJSON(String)
    case exportText(String)
    case editTitle(String)
    case regenerateTitle(String)
    case lockSession(String)
    case unlockSession(String)
    case duplicate(String)
    case forceSync(String)
    case forcePull(String)
    case select(String)
    case moveToFolder(String)
    case delete(String)
}
