// Demo extension slash command that reads the author-declared settings
// (manifest.json `settings`) via minis.api.settings.get. Users can change
// these on the extension's ⚙️ Settings page in the Extension manager.
//
// This handler is async on purpose: it returns a Promise, and the host
// waits for it before showing the result — you can also just return a
// plain value. `args` is an array of whitespace-separated words from the
// typed command: "/ext-hello Alice Bob" → ["Alice", "Bob"].
minis.registerCommand({
  name: "ext-hello",
  description: "Says hello using the extension's settings (prefix, uppercase, mode).",
  handler: function (args) {
    return new Promise(function (resolve) {
      var prefix = minis.api.settings.get("greetingPrefix") || "Hello";
      var uppercase = minis.api.settings.get("uppercase") === true;
      var mode = minis.api.settings.get("replyMode") || "friendly";
      var name = (args && args.length ? args.join(" ") : "").trim() || "world";
      var msg = prefix + ", " + name + "!";
      if (uppercase) msg = msg.toUpperCase();
      if (mode === "laconic") msg = prefix + " " + name;
      if (mode === "formal") msg = prefix + ", " + name + ". It is a pleasure.";
      resolve(msg + "  [mode=" + mode + "]");
    });
  },
});
