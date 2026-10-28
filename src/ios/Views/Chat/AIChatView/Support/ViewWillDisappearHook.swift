//
//  ViewWillDisappearHook.swift
//  Minis - chat page (AIChatView)
//
//  ViewWillDisappearHook: runs an action once the page is really leaving (a
//  committed pop), used to lower the keyboard during the pop animation.
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

/// [T-pop-keyboard-flash-home] Runs `action` once the page is really leaving,
/// timed like iMessage: SwiftUI's `onDisappear` only fires after the
/// transition has finished, which is too late (the keyboard's dismissal then
/// plays over the next screen).
/// - Non-interactive (back button, programmatic pop, cover): at the start of
///   the transition, so the keyboard slides away with the page.
/// - Interactive back swipe: nothing while the finger drags (the keyboard stays
///   put, as in iMessage); when the finger lifts and the pop is COMMITTED, run
///   it so the keyboard goes down during the remaining animation. A cancelled
///   swipe leaves the keyboard alone.
/// The hook is a child view controller of the hosting controller, which
/// forwards appearance callbacks to it.
///
/// [T-pop-keyboard-late-autofocus] `onWillAppear` runs on every viewWillAppear
/// (first push, and the page coming back after a full-screen cover), so a
/// "leaving" state set by `action` is cleared whenever the page is shown again.
struct ViewWillDisappearHook: UIViewControllerRepresentable {
    let action: () -> Void
    var onWillAppear: () -> Void = {}

    func makeUIViewController(context: Context) -> Controller {
        let c = Controller()
        c.action = action
        c.onWillAppear = onWillAppear
        return c
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.action = action
        controller.onWillAppear = onWillAppear
    }

    final class Controller: UIViewController {
        var action: () -> Void = {}
        var onWillAppear: () -> Void = {}

        override func loadView() {
            let v = UIView()
            v.isUserInteractionEnabled = false
            v.backgroundColor = .clear
            view = v
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            onWillAppear()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard let coordinator = transitionCoordinator, coordinator.isInteractive else {
                action()
                return
            }
            coordinator.notifyWhenInteractionChanges { [weak self] context in
                guard !context.isCancelled else { return }
                self?.action()
            }
        }
    }
}

// BEGIN PageLeaveLatch
/// [T-pop-keyboard-late-autofocus] Remembers that the chat page has COMMITTED
/// to leaving (set from ViewWillDisappearHook's action), until it is shown
/// again (cleared from viewWillAppear / onAppear).
///
/// Why `isChatViewVisible` is not enough: it only turns false in onDisappear,
/// which SwiftUI fires well after the pop has finished (iOS 27 device log:
/// ~530-590 ms after viewWillDisappear, while the pop is visually over after
/// ~340 ms). A delayed composer focus (new-draft 0.6 s, after-reply 1.5 s,
/// share 0.3 s, transfer 0.6 s) that fires in that gap passed the guard and
/// raised the keyboard over the home screen. The composer's own
/// `leavingTransition` check cannot see it either: the transition is over.
///
/// A cancelled interactive swipe never reaches the hook's action, so it never
/// sets the latch and the page keeps its delayed focus.
final class PageLeaveLatch {
    private(set) var isLeaving = false

    func markLeaving() { isLeaving = true }
    func markAppeared() { isLeaving = false }

    /// Whether a delayed (timer-driven) composer focus may still run.
    func allowsDelayedFocus(isVisible: Bool) -> Bool {
        isVisible && !isLeaving
    }
}
// END PageLeaveLatch
