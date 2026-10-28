import AppIntents
import Foundation

/// [T-shortcut-envvar] "Save Environment Variable to Minis" — store text a
/// Shortcut captured (a received SMS, clipboard, a note…) as the global
/// environment variable `MINIS_SHORTCUT_OPT_<SUFFIX>`.
///
/// Same storage as a variable added under Settings → Environment Variables
/// (name in env-vars.json, value in the synchronizable Keychain), so:
///   - every session's shell sees it from its next command — no relaunch
///     needed, the shell environment is read per command;
///   - the user can edit or delete it on that settings page;
///   - saving the same suffix again replaces the value.
///
/// Runs in the background (`openAppWhenRun = false`) so an automation such as
/// "when a message arrives" can call it without bringing Minis forward. The
/// Keychain item and the key file are both readable after first unlock, so
/// this also works while the device is locked. Returns the variable name for
/// later actions.
///
/// Not registered in MinisShortcutsProvider: it is a building block for the
/// user's own Shortcuts, found under the app's actions, with no Siri phrase
/// of its own.
struct SaveEnvVarIntent: AppIntent {
    static var title: LocalizedStringResource = "Save Environment Variable to Minis"
    static var description = IntentDescription("Saves text from Shortcuts, such as a received message, as the environment variable MINIS_SHORTCUT_OPT_ followed by the name suffix. Every Minis session can read it in the shell, saving the same name again updates it, and it can be deleted under Settings → Environment Variables.")
    static var openAppWhenRun = false

    @Parameter(title: "Text",
               description: "The text to store, for example the content of a message. Up to 32 KB.",
               requestValueDialog: "What text should Minis store?",
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String

    @Parameter(title: "Name Suffix",
               description: "Letters, digits and underscores, for example SMS_CODE. The variable is named MINIS_SHORTCUT_OPT_ followed by this suffix.",
               requestValueDialog: "What name suffix should the variable use?")
    var suffix: String

    // [T-shortcut-envvar-summary] The fixed prefix sits right before the
    // suffix field, so the action line reads as the whole variable name the
    // user will reference: "…as $MINIS_SHORTCUT_OPT_[Name Suffix]".
    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$text) to Minis as $MINIS_SHORTCUT_OPT_\(\.$suffix)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = self.text
        let suffix = self.suffix
        let saved = try await MainActor.run {
            try EnvVarStore.shared.saveFromShortcut(suffix: suffix, text: text)
        }
        // [T-shortcut-envvar-howto] Tell the user what they can do next — the
        // variable is otherwise invisible from Shortcuts. The result VALUE
        // stays the bare name so later actions can chain it.
        let key = saved.key
        // [T-envvar-disable] Saving keeps a disabled variable disabled; say
        // so, since "ask Minis to read it" would not work.
        let disabled = await MainActor.run {
            EnvVarStore.shared.entries.contains { $0.key == key }
                && !EnvVarStore.isKeyEnabledSync(key)
        }
        if disabled {
            let message = AppLocalized("Updated \(key). It is disabled, so Minis cannot read it until you enable it in Minis → Settings → Environment Variables.")
            return .result(value: key, dialog: IntentDialog(stringLiteral: message))
        }
        let message = saved.created
            ? AppLocalized("Saved as \(key).\nTo use it, ask Minis in any chat to read $\(key).\nTo view, edit or delete it, open Minis → Settings → Environment Variables.")
            : AppLocalized("Updated \(key).\nTo use it, ask Minis in any chat to read $\(key).\nTo view, edit or delete it, open Minis → Settings → Environment Variables.")
        return .result(value: key, dialog: IntentDialog(stringLiteral: message))
    }
}
