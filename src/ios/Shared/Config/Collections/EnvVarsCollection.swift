import Foundation

/// Exposes EnvVarStore entries under `envvars.<key>.…`.
///
/// IMPORTANT: values are NEVER exposed — neither read nor write here.
/// The agent can list keys, attach a note, or remove a variable, but
/// the actual secret only ever moves through Keychain and the user-
/// facing UI. Adding a variable goes through this collection too, but
/// the agent must use the existing
/// `minis://settings/environments?create_key=…` deep link if it wants
/// the user to populate the value — there's no programmatic write
/// path that accepts a value.
@MainActor
struct EnvVarsCollection: ConfigCollection {
    let basePath = "envvars"
    let displayName = "Environment variables"
    let description = "Metadata only — values are stored in Keychain and never exposed."
    var addable: Bool { false }      // adding requires a value, which we never accept
    var removable: Bool { true }
    let risk: ConfigRisk = .sensitive

    let addPayloadSchema: ConfigValueSchema = .json

    func childIds() -> [String] {
        EnvVarStore.shared.entries.map(\.key)
    }

    func fields(for id: String) -> [ConfigField] {
        guard entry(id) != nil else { return [] }
        return [
            createdAtField(for: id),
            noteField(for: id),
            enabledField(for: id),
            // Hidden guard: an agent attempting to read or write the
            // value gets a precise permission_denied.
            HiddenField(
                path: "envvars.\(id).value",
                displayName: "Value",
                description: "Hidden — manage via Settings → Environment Variables.",
                reason: "Env var values are stored in Keychain and never exposed to minis-config"
            ),
        ]
    }

    func add(_ payload: ConfigValue) throws -> String {
        throw ConfigError.permissionDenied(
            reason: "Use the deep link `minis://settings/environments?create_key=…` so the user enters the value directly"
        )
    }

    func remove(id: String) throws {
        guard let e = entry(id) else { throw ConfigError.unknownPath("envvars.\(id)") }
        EnvVarStore.shared.delete(id: e.id)
    }

    // MARK: [T-config-readable] Readable descriptions
    //
    // Only the variable NAME ever appears; there is no code path here that can
    // reach a value (values live in Keychain and minis-config never reads them).

    let readableSubjectFormat = "Environment variable $%1$@ – %2$@"

    func entityLabel(id: String) -> String? {
        entry(id)?.key
    }

    /// `add` is refused (a value is required); nothing to describe.
    func readableForAdd(_ payload: RedactedConfigValue) -> [ReadableLine] { [] }

    func readableForRemove(id: String) -> [ReadableLine] {
        guard let e = entry(id) else { return [] }
        return [ReadableLine("Delete environment variable $%@ (its value is removed from Keychain)", [.text(e.key)])]
    }

    private func entry(_ key: String) -> EnvVarEntry? {
        EnvVarStore.shared.entries.first { $0.key == key }
    }

    private func createdAtField(for key: String) -> ConfigField {
        ReadOnlyField(
            path: "envvars.\(key).createdAt",
            displayName: "Created at",
            description: "ISO-8601 timestamp.",
            valueSchema: .string(),
            reader: { [self] in
                guard let e = entry(key) else { return .null }
                return .string(ISO8601DateFormatter().string(from: e.createdAt))
            }
        )
    }

    /// [T-envvar-disable] Sensitive: enabling a variable puts its secret
    /// back into every shell the agent runs, so a write goes through the
    /// user's confirmation sheet ("Enabled" / "Disabled (environment
    /// variable)" are localized; the latter reads 已禁用 in zh-Hans).
    private func enabledField(for key: String) -> ConfigField {
        ClosureField(
            path: "envvars.\(key).enabled",
            displayName: "Enabled",
            description: "Whether the variable is put into the shell / process environment. A disabled variable keeps its value and note, is still masked in output, and a $$NAME reference to it resolves to an empty value (with a warning).",
            valueSchema: .bool,
            risk: .sensitive, revertable: true,
            readable: ConfigReadable(.bool(on: "Enabled", off: "Disabled (environment variable)")),
            reader: { [self] in
                guard let e = entry(key) else { return .null }
                return .bool(EnvVarStore.shared.isEnabled(id: e.id))
            },
            writer: { [self] v in
                guard case .bool(let b) = v else { throw ConfigError.typeMismatch(expected: "bool") }
                guard let e = entry(key) else { throw ConfigError.unknownPath("envvars.\(key)") }
                EnvVarStore.shared.setEnabled(id: e.id, b)
            }
        )
    }

    private func noteField(for key: String) -> ConfigField {
        ClosureField(
            path: "envvars.\(key).note",
            displayName: "Note",
            description: "Free-form description (not secret). Empty string clears it.",
            valueSchema: .string(maxLength: 500),
            risk: .normal, revertable: true,
            readable: ConfigReadable(.text(preview: 60)),
            reader: { [self] in
                guard let e = entry(key) else { return .null }
                return .string(e.note)
            },
            writer: { [self] v in
                guard case .string(let s) = v else { throw ConfigError.typeMismatch(expected: "string") }
                guard let e = entry(key) else { throw ConfigError.unknownPath("envvars.\(key)") }
                // updateNote bypasses the value-aware update path so
                // we never need to read or rewrite the Keychain
                // secret to change a description.
                EnvVarStore.shared.updateNote(id: e.id, note: s)
            }
        )
    }
}
