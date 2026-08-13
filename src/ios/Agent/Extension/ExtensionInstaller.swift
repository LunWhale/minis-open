import Foundation

// MARK: - Extension Installer

/// Installs `.minisx` zip bundles: read zip entries, locate + parse
/// manifest.json, validate file references, unpack to
/// `Library/MinisChat/extensions/<id>/`, and register in ExtensionStore.
///
/// Zip reading reuses SkillStore's proven parser (deflate + stored entries,
/// no external dependencies).
enum ExtensionInstaller {

    /// Install an extension from a .minisx zip file URL.
    static func install(from url: URL) async throws -> ExtensionManifest {
        let data = try Data(contentsOf: url)
        return try await install(data: data)
    }

    /// Install from raw zip data.
    static func install(data: Data) async throws -> ExtensionManifest {
        let entries = try SkillStore.readZipEntries(data: data)

        // Locate manifest.json (root or one level deep).
        guard let manifestEntry = entries.first(where: { $0.name.hasSuffix("manifest.json") }) else {
            throw ExtensionError.missingManifest
        }
        guard !manifestEntry.isDirectory else {
            throw ExtensionError.missingManifest
        }
        let manifestData = manifestEntry.data
        let manifest = try ExtensionManifest.parse(data: manifestData)

        // Reject duplicate installs (same version).
        if let existing = try? await ExtensionStore.shared.get(id: manifest.id),
           existing.version == manifest.version {
            throw ExtensionError.duplicateID(manifest.id)
        }

        // Strip the manifest's parent dir prefix (e.g. "my-ext/manifest.json" → "").
        var prefix = ""
        if manifestEntry.name != "manifest.json" {
            prefix = String(manifestEntry.name.dropLast("manifest.json".count))
        }

        // Unpack to extensions/<id>/.
        let store = ExtensionStore.shared
        let bundleRoot = store.extensionsDir.appendingPathComponent(manifest.id, isDirectory: true)
        let fm = FileManager.default
        // Remove any stale bundle (upgrade path).
        try? fm.removeItem(at: bundleRoot)
        try fm.createDirectory(at: bundleRoot, withIntermediateDirectories: true)

        for entry in entries where !entry.isDirectory {
            var rel = entry.name
            if !prefix.isEmpty && rel.hasPrefix(prefix) {
                rel = String(rel.dropFirst(prefix.count))
            }
            // Skip the manifest itself and dotfiles.
            if rel == "manifest.json" || rel.hasPrefix(".") || rel.isEmpty { continue }

            let dest = bundleRoot.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.data.write(to: dest)
        }

        // Validate declared file references now that everything is unpacked.
        try manifest.validateFileReferences(bundleRoot: bundleRoot)

        // Register.
        try await store.register(manifest: manifest)

        return manifest
    }
}
