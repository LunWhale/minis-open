import Foundation

/// Reads and writes PendingShare data to the App Group shared container.
/// Compiled into both the main app target and the Share Extension target.
enum SharedContainerStore {
    /// App Group identifier shared by the app and its three extensions.
    ///
    /// ── CONFIGURATION POINT ──────────────────────────────────────────────
    /// Change this line to use your OWN App Group. App Group identifiers are
    /// scoped to a developer TEAM, so with a paid account you can register
    /// `group.com.openminis.app` on your own team, or use any name you like.
    ///
    /// If you change it, change the same literal in all four entitlement files
    ///   src/ios/Minis.entitlements
    ///   src/ios/ShareExtension/ShareExtension.entitlements
    ///   src/ios/FileProvider/FileProvider.entitlements
    ///   src/ios/AgentWidget/AgentWidget.entitlements
    /// and make sure your provisioning profile grants it. `AppGroupFallbackTests`
    /// fails when these five places disagree, so the drift cannot go unnoticed.
    ///
    /// Without the group the app still runs: `resolvedContainerRoot` falls back
    /// to a sandbox directory, and only the cross-process features (Share
    /// extension, Files-app/FileProvider browsing, widget shared defaults) degrade.
    /// ─────────────────────────────────────────────────────────────────────
    static let appGroupID = "group.com.openminis.app"

    /// App Group container root with a sandbox fallback.
    ///
    /// When the App Group entitlement is honored (App Store build, normal
    /// sideload, LiveContainer overlay) this returns the real group
    /// container. Under re-signing (TrollStore, changed bundle ID, stripped
    /// entitlements) `containerURL(forSecurityApplicationGroupIdentifier:)`
    /// returns nil — we fall back to a sandbox-local directory instead of
    /// crashing on a force-unwrap. FileProvider/Files-app sharing degrades
    /// gracefully in fallback mode; all in-app features keep working.
    static var resolvedContainerRoot: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return url
        }
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let fallback = lib.appendingPathComponent("AppGroupFallback", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// True when the real App Group entitlement is honored.
    static var appGroupEntitled: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }

    private static let pendingShareKey = "pendingShare"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Directory in the shared container for transferring attachment files.
    static var sharedFileDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("ShareExtension", isDirectory: true)
    }

    // MARK: - Write (called by Share Extension)

    static func savePendingShare(_ share: PendingShare) {
        guard let defaults = sharedDefaults else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(share) {
            defaults.set(data, forKey: pendingShareKey)
            defaults.synchronize()
        }
    }

    // MARK: - Read & Consume (called by main app)

    static func loadPendingShare() -> PendingShare? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: pendingShareKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingShare.self, from: data)
    }

    static func clearPendingShare() {
        sharedDefaults?.removeObject(forKey: pendingShareKey)
        sharedDefaults?.synchronize()
    }

    /// Remove all files from the shared transfer directory.
    static func cleanSharedFiles() {
        guard let dir = sharedFileDirectory else { return }
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }
}
