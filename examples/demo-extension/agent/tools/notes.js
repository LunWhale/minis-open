// Demo extension: file API showcase.
//
// The file API maps /var/minis/** guest paths to the app's real storage:
//   /var/minis/shared/**   → persistent, shared across sessions
//   /var/minis/memory/**   → persistent memory dir
//   /var/minis/skills/**   → skills dir
//   /var/minis/workspace, /attachments, /offloads, /browser → per-session
//
// Every call returns a Promise. Requires the "files" permission.
var NOTES_DIR = "/var/minis/shared/demo-notes";

minis.registerTool({
  name: "demo_notes",
  description: "Demo of the file API. Actions: list (default) | read | write | delete.",
  parameters: {},
  execute: function (args) {
    var action = (args && args.action) || "list";
    var name = (args && args.name) || "note.txt";
    var path = NOTES_DIR + "/" + name;

    if (action === "list") {
      return minis.api.file.list(NOTES_DIR).then(function (json) {
        var entries = JSON.parse(json);
        if (!entries.length) return "No notes yet. Write one with action=write.";
        return entries.map(function (e) {
          return "- " + e.name + (e.isDirectory ? "/" : " (" + e.size + " bytes)");
        }).join("\n");
      });
    }
    if (action === "read") {
      return minis.api.file.read(path);
    }
    if (action === "write") {
      var content = (args && args.content) || "hello from the demo extension";
      return minis.api.file.write(path, content);
    }
    if (action === "delete") {
      return minis.api.file.delete(path);
    }
    return "Error: unknown action '" + action + "' (use list | read | write | delete)";
  },
});
