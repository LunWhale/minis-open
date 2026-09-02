import Foundation
import UIKit
import UniformTypeIdentifiers

private let importLog = AppLogger(category: "Share")

/// Presents a modal that was requested from *inside* a `Menu` or
/// `.confirmationDialog` button, one animation cycle after the tap.
///
/// Both of those controls dismiss themselves when their button fires. Setting a
/// `isPresented: true` binding in the same runloop turn makes SwiftUI present
/// the new modal while the menu/dialog is still tearing down, and the two
/// presentations collide on the same hosting controller. The observable
/// failure is not "nothing happens" — the picker does appear — but it lands on
/// a controller that is going away, so taps on rows are swallowed, or the pick
/// completes and SwiftUI drops the result because the coordinator that asked
/// for it no longer exists. That is the "文件管理器弹出来了，但选不了 / 选完没反应"
/// symptom on Settings → Providers (Import), the chat `+` attachment menu, and
/// every other menu-driven import in the app.
///
/// 0.25 s is not arbitrary: it is the same interval this app already uses to
/// sequence one alert behind another (CloudSyncSettingsView), i.e. the time it
/// takes the system dismissal animation to finish on the slowest device class.
/// A plain `.async` is NOT enough here — the menu's own dismissal is scheduled
/// on a later turn than the button action.
enum DeferredPresentation {
    /// Interval that lets a menu/dialog finish dismissing before the next modal
    /// is presented. Kept as one named constant so every call site agrees.
    static let menuDismissInterval: TimeInterval = 0.25

    static func afterMenuDismiss(_ present: @escaping @MainActor () -> Void) {
        let nanos = UInt64(menuDismissInterval * 1_000_000_000)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanos)
            present()
        }
    }
}

/// Reads/copies a file the user just picked in a document picker.
///
/// Two properties of picker-returned URLs break the naive implementation, and
/// both were reported as "选了文件但没上传":
///
///  * `.fileImporter` hands back a copy **inside our own container** for most
///    providers, so `startAccessingSecurityScopedResource()` returns `false`.
///    `false` means "this URL was never scoped", NOT "access denied" — treating
///    it as a failure rejects every working file.
///  * A file still in iCloud (`status = not-downloaded`) cannot be read
///    directly; an `NSFileCoordinator` *read assertion* is what asks the
///    provider to materialize it first. This is the same recipe
///    `ExternalFileImporter.ingest` uses.
enum FilePickIngest {

    /// Copy a picked file to `dest`. Throws only if the file genuinely could not
    /// be read or written; the error is worth showing to the user.
    static func copy(from src: URL, to dest: URL) throws {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [], error: &coordinationError) { readURL in
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: readURL, to: dest)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        guard copyError == nil else { throw copyError! }
    }

        /// Read a picked file's bytes, same tolerances as `copy`.
    static func read(_ src: URL) throws -> Data {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        var data: Data?
        var readError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [], error: &coordinationError) { readURL in
            do {
                data = try Data(contentsOf: readURL, options: [.mappedIfSafe])
            } catch {
                readError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let data { return data }
        throw readError ?? CocoaError(.fileReadUnknown)
    }

    /// `.fileImporter` reports a dismissed picker as a failure, so call sites must
    /// not turn a cancel into an error dialog. Both codes are seen in the wild
    /// depending on the iOS version.
    static func isUserCancellation(_ error: Error) -> Bool {
        let ns = error as NSError
        // NSFileCancelledOperation / "user cancelled" is CocoaError 1001.
        return (ns.domain == NSCocoaErrorDomain && ns.code == 1001)
            || (ns.domain == NSURLErrorDomain && ns.code == URLError.cancelled.rawValue)
    }

    /// Read a picked text file, accepting the encodings an exported config
    /// actually arrives in. `String(data:encoding:.utf8)` returns nil for UTF-16
    /// (what TextEdit / Windows editors and some export tools write), which
    /// surfaced as "Failed to read file" on a perfectly good JSON file.
    static func readText(_ src: URL) throws -> String {
        let data = try read(src)
        for encoding: String.Encoding in [.utf8, .utf16, .utf16LittleEndian, .isoLatin1] {
            if let s = String(data: data, encoding: encoding) {
                // A BOM or a stray NUL in the first bytes means we guessed the
                // wrong endianness — utf16 vs utf16LittleEndian both "decode".
                if encoding == .utf8 || !s.contains("\0") { return s }
            }
        }
        throw CocoaError(.fileReadInvalidFileName)
    }
}

/// Presents a `UIDocumentPickerViewController` from the topmost view controller.
///
/// [T-uikit-docpicker] `.fileImporter` broke hard on this device class: the picker
/// window appears, but taps on files are swallowed — no dismissal, no result, no
/// error (reported across TrollStore / Sideloadly / Xcode installs). The picker
/// is being presented onto a presentation context SwiftUI is already tearing down,
/// so its delegate never fires. UIKit presentation from the CURRENT topmost VC
/// bypasses SwiftUI's coordinator entirely and restores selection.
///
/// The coordinator is retained statically until the picker closes (pick or
/// cancel), and presentation is deferred one beat so it never collides with a
/// Menu / confirmationDialog dismissal — same reason DeferredPresentation exists.
enum DocumentPickerBridge {
    private static var activeCoordinator: Coordinator?

    @MainActor
    static func present(
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool = false,
        handler: @escaping @MainActor ([URL]) -> Void
    ) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(DeferredPresentation.menuDismissInterval * 1_000_000_000))
            guard let presenter = Self.topPresenter() else {
                importLog.error("[DocPicker] no presenter available")
                return
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedContentTypes, asCopy: true)
            picker.allowsMultipleSelection = allowsMultipleSelection
            let coordinator = Coordinator(handler: handler)
            picker.delegate = coordinator
            activeCoordinator = coordinator
            if let pop = picker.popoverPresentationController {
                pop.sourceView = presenter.view
                pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            }
            presenter.present(picker, animated: true)
        }
    }

    @MainActor
    private static func topPresenter() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let rootVC = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController else {
            return nil
        }
        var top = rootVC
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    private final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let handler: @MainActor ([URL]) -> Void

        init(handler: @escaping @MainActor ([URL]) -> Void) {
            self.handler = handler
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(controller, urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(controller, [])
        }

        private func finish(_ controller: UIDocumentPickerViewController, _ urls: [URL]) {
            let handler = self.handler
            controller.dismiss(animated: true)
            DocumentPickerBridge.activeCoordinator = nil
            Task { @MainActor in handler(urls) }
        }
    }
}

/// Ingests a `file://` URL that arrived via "Open in Minis" / "Copy to Minis"
/// from the Files app (or any document provider) into the SAME PendingShare
/// pipeline the Share Extension uses. The file is copied into the App Group
/// shared transfer directory and surfaced as a `.attachment` item, so it flows
/// through AIChatView.injectPendingShareIfNeeded — which already detects a
/// Provider-export JSON and prompts import-vs-attach (#678). No separate
/// detection path. [T-ios-json-open-provider-import-prompt]
enum ExternalFileImporter {

    /// True if `url` is a local file we should ingest (vs a `minis://` deep link).
    static func canIngest(_ url: URL) -> Bool {
        url.isFileURL
    }

    /// Copy the incoming file into the shared transfer dir and raise a pending
    /// share so the normal consume → detect → prompt flow runs. Returns true if
    /// the file was staged. Files-app URLs are typically security-scoped, so we
    /// bracket the read with start/stopAccessingSecurityScopedResource and copy
    /// into our sandbox before the scope is released.
    @discardableResult
    static func ingest(_ url: URL, into coordinator: ShareCoordinator) -> Bool {
        guard url.isFileURL else { return false }
        guard let dir = SharedContainerStore.sharedFileDirectory else {
            importLog.error("[Share] ingest: sharedFileDirectory is nil — cannot stage \(url.lastPathComponent)")
            return false
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Use a unique on-disk name to avoid colliding with a concurrent share,
        // but keep the original extension so downstream type checks (e.g. the
        // .json gate in providerExportJSON) still work.
        let ext = url.pathExtension
        let stagedName = "open-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
        let dest = dir.appendingPathComponent(stagedName)
        do {
            // NSFileCoordinator gives the document provider a chance to
            // materialize a not-yet-downloaded iCloud file before we copy.
            var coordErr: NSError?
            var copyErr: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordErr) { readURL in
                do {
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.copyItem(at: readURL, to: dest)
                } catch { copyErr = error }
            }
            if let coordErr { throw coordErr }
            if let copyErr { throw copyErr }
        } catch {
            importLog.error("[Share] ingest: failed to copy \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }

        let share = PendingShare(
            items: [PendingShare.Item(kind: .attachment, value: stagedName)],
            timestamp: Date()
        )
        SharedContainerStore.savePendingShare(share)
        importLog.info("[Share] ingest: staged \(url.lastPathComponent) as \(stagedName) and raising pending share")
        Task { @MainActor in coordinator.raisePendingShare() }
        return true
    }
}
