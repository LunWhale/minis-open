//
//  UserActivityMonitor.swift
//  MinisApp
//
//  [T-always-on] Tells AlwaysOnController when the user last did something,
//  so it can tell "watching the task" from "put the phone down".
//
//  Touches: a gesture recognizer on every app window that only observes. It
//  never recognizes, never cancels or delays touches and runs simultaneously
//  with every other recognizer, so no existing interaction changes. Sheets live
//  in the same window, so they are covered too.
//  Typing: the system keyboard runs in another process and its key taps never
//  reach our windows, so text changes and keyboard frame changes count too.
//  Windows that adopt AlwaysOnExcludedWindow (the Always On overlay itself) are
//  skipped: a tap there is handled by the overlay.
//

import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Marks a window whose touches are not "activity" (the Always On overlay).
protocol AlwaysOnExcludedWindow: UIWindow {}

@MainActor
final class UserActivityMonitor {
    private var onActivity: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private let installed = NSHashTable<UIWindow>.weakObjects()
    private var lastReport = Date.distantPast
    /// Touch moves arrive at the display rate; one report per interval is enough.
    private static let throttle: TimeInterval = 0.5

    func start(onActivity: @escaping () -> Void) {
        self.onActivity = onActivity
        installOnAllWindows()
        let center = NotificationCenter.default
        // New windows (a scene connecting, the keyboard's host window, alerts).
        observers.append(center.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? UIWindow else { return }
                self.install(on: window)
            }
        })
        let typing: [Notification.Name] = [
            UITextField.textDidChangeNotification,
            UITextView.textDidChangeNotification,
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillChangeFrameNotification,
        ]
        for name in typing {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.report(force: true) }
            })
        }
    }

    private func installOnAllWindows() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { install(on: window) }
        }
    }

    private func install(on window: UIWindow) {
        guard !(window is AlwaysOnExcludedWindow), !installed.contains(window) else { return }
        let recognizer = ActivityObservingGestureRecognizer { [weak self] in self?.report(force: false) }
        window.addGestureRecognizer(recognizer)
        installed.add(window)
    }

    private func report(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= Self.throttle else { return }
        lastReport = now
        onActivity?()
    }
}

/// Observes touches without taking part in gesture handling.
final class ActivityObservingGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let onTouch: () -> Void

    init(onTouch: @escaping () -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()   // a long drag or scroll is activity the whole time
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        state = .failed   // never recognizes; failing lets UIKit reset it
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
