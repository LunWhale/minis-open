import UIKit

/// The Share Extension's principal view controller.
///
/// It has no UI of its own: it reads what was shared, hands it to the app
/// through the App Group, opens the app and ends the request.
///
/// [T-share-one-link] The request is ended exactly once, on every path, and
/// within a bounded time:
///   - nothing usable was shared      → cancelRequest, the app is not opened
///   - content saved                  → open the app, then completeRequest
///   - a provider never returns       → after `processingLimit` go on with
///                                      what was loaded, or cancel
///   - the open never reports back    → complete anyway after `openGrace`
/// Before, a fast share ended the request twice (once when processing
/// finished and again from viewDidAppear), and a provider that never returned
/// left an invisible view over the host app with nothing to end it.
class ShareViewController: UIViewController {

    /// Longest time spent loading the shared items.
    private static let processingLimit: TimeInterval = 8
    /// Longest wait for the app-open to report back before completing anyway.
    private static let openGrace: TimeInterval = 1.5

    /// Set by `finish`; every later call is ignored.
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        NSLog("[ShareExt] viewDidLoad — starting processing")

        Task { @MainActor in
            let vm = ShareViewModel()
            let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
            NSLog("[ShareExt] inputItems count: %d", items.count)

            let timedOut = await processWithLimit(vm, items)
            if timedOut {
                NSLog("[ShareExt] processing exceeded %.0fs — continuing with what was loaded", Self.processingLimit)
                vm.finalizeItems()
            }

            let saved = vm.save()
            NSLog("[ShareExt] save() returned: %@ (%d items)", saved ? "true" : "false", vm.itemCount)

            switch ShareItemRules.finish(savedItemCount: saved ? vm.itemCount : 0) {
            case .cancel:
                finish(.cancel)
            case .openAppThenComplete:
                // Complete when the open reports back, or after a short grace
                // period if it never does. `finish` takes the first of the two.
                openHostApp { [weak self] in self?.finish(.openAppThenComplete) }
                try? await Task.sleep(nanoseconds: UInt64(Self.openGrace * 1_000_000_000))
                finish(.openAppThenComplete)
            }
        }
    }

    /// Runs the item processing, giving up waiting after `processingLimit`.
    /// Returns true when the limit was hit. The load that is still suspended
    /// is left alone: the extension process ends with the request.
    private func processWithLimit(_ vm: ShareViewModel, _ items: [NSExtensionItem]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var resumed = false   // main actor only
            Task { @MainActor in
                await vm.processExtensionItems(items)
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: false)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.processingLimit * 1_000_000_000))
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: true)
            }
        }
    }

    /// The only place the request is ended.
    private func finish(_ how: ShareItemRules.Finish) {
        guard !finished else { return }
        finished = true
        switch how {
        case .cancel:
            NSLog("[ShareExt] nothing to hand over — cancelling request")
            extensionContext?.cancelRequest(withError: NSError(
                domain: "com.openminis.app.ShareExtension", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Nothing in this share could be read."]))
        case .openAppThenComplete:
            NSLog("[ShareExt] completing request")
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    // MARK: - Redirect to main app

    /// Opens `minis://share` through the UIApplication found in the responder
    /// chain. `done` runs on the main thread once the open reported back, or
    /// at once when it could not be attempted.
    private func openHostApp(_ done: @escaping () -> Void) {
        guard let url = URL(string: "minis://share") else {
            NSLog("[ShareExt] ERROR: Failed to create minis://share URL")
            done()
            return
        }

        let selectorOpenURL = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                NSLog("[ShareExt] Found UIApplication in responder chain, opening URL")
                if #available(iOS 18.0, *) {
                    application.open(url, options: [:]) { success in
                        NSLog("[ShareExt] open reported: %@", success ? "true" : "false")
                        DispatchQueue.main.async { done() }
                    }
                } else {
                    application.perform(selectorOpenURL, with: url)
                    done()
                }
                return
            }
            responder = responder?.next
        }
        // The share is saved; the app picks it up the next time it is opened
        // (ShareCoordinator.checkForPendingShare).
        NSLog("[ShareExt] WARNING: UIApplication not found in responder chain!")
        done()
    }
}
