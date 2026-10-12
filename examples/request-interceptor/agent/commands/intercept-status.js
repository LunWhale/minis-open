// Slash command: show what the request interceptor is currently doing.
// Demonstrates an async command handler (returns a Promise) and reading
// extension settings.
minis.registerCommand({
  name: "ext-intercept-status",
  description: "Shows the request-interceptor demo configuration.",
  handler: function () {
    return new Promise(function (resolve) {
      var enabled = minis.api.settings.get("enabled");
      var tag = minis.api.settings.get("tag") || "minis-open";
      var provider = minis.api.settings.get("provider") || "any";
      var verbose = minis.api.settings.get("verbose") !== false;
      var lines = [
        "Request Interceptor Demo",
        "- status:   " + (enabled === false ? "disabled" : "active"),
        "- header:   X-Plugin-Tag: " + tag,
        "- provider: " + (provider === "any" ? "all providers" : provider),
        "- logging:  " + (verbose ? "on (see Extensions → scroll icon)" : "off"),
        "",
        "Every matching model request gets the header injected by the plugin",
        "(no proxy / relay needed). Change these values on the extension's",
        "settings page (⚙️ in Settings → Extensions).",
      ];
      resolve(lines.join("\n"));
    });
  },
});
