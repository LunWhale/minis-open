// Demo extension slash command that reads the author-declared settings
// (manifest.json `settings`) via minis.api.settings.get. Users can change
// these on the extension's ⚙️ Settings page in the Extension manager.
minis.registerCommand({
  name: "ext-hello",
  description: "Says hello using the extension's settings (prefix, uppercase, mode).",
  handler: function (args) {
    var prefix = minis.api.settings.get("greetingPrefix") || "Hello";
    var uppercase = minis.api.settings.get("uppercase") === true;
    var mode = minis.api.settings.get("replyMode") || "friendly";
    var name = (args && args.trim && args.trim()) || "world";
    var msg = prefix + ", " + name + "!";
    if (uppercase) msg = msg.toUpperCase();
    if (mode === "laconic") msg = prefix + " " + name;
    if (mode === "formal") msg = prefix + ", " + name + ". It is a pleasure.";
    return msg + "  [mode=" + mode + "]";
  },
});
