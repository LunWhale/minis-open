//
//  ComposerActionChannel.swift
//  Minis - chat page (AIChatView)
//
//  Class relays that keep closures out of composer views: SendPrimaryActionBox
//  (the send menu's tap action) and ComposerActionChannel (the composer's key
//  callbacks, wired in AIChatView+InputBar.swift).
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

/// [T-send-menu-stale-primary-action] Mutable holder for the send Menu's tap
/// action; see `ChatSendButton.primaryActionBox`.
@MainActor
final class SendPrimaryActionBox {
    var action: () -> Void = {}
}

/// [T-ios-crash-objectdestroy-composer-uaf] Action relay for the composer's
/// key callbacks, the same pattern as ContentView's FABActionChannel.
///
/// PastableTextView stores its callbacks as escaping closures. When those
/// closures captured AIChatView (instance-method references such as
/// `handleReturnKey`, or `vm` read through `self`), each one dragged a whole
/// AIChatView copy into a heap context; SwiftUI graph teardown then destroyed
/// that stale copy after its @State storage was gone — the
/// `objectdestroy.NNTm` use-after-free seen under `destroy for
/// PastableTextView`. Routing through a class with a stable lifetime means the
/// stored closures capture only this one reference.
@MainActor
final class ComposerActionChannel {
    enum Action { case returnKey, arrowUp, arrowDown, tab, caret(Int), submitAfterVoice, releaseFocus }
    var handler: ((Action) -> Bool)?
    /// Returns the handler's "consumed" answer (false when not wired yet, so
    /// an early arrow/tab key keeps its default text-view behaviour).
    @discardableResult
    func send(_ action: Action) -> Bool { handler?(action) ?? false }
}
