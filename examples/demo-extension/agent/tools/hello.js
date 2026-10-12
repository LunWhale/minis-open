// Demo extension: agent tool.
// Registered via minis.registerTool. The `execute` function receives args
// (JSON object) and may return a string, an object (stringified), or a
// Promise of either — the host awaits Promises before handing the result
// back to the model.
minis.registerTool({
  name: "hello_world",
  description: "Returns a greeting. Demonstrates a minimal extension tool.",
  parameters: {},
  execute: function (args) {
    var who = (args && args.name) || "world";
    return new Promise(function (resolve) {
      resolve("Hello, " + who + "! This tool ran from the Demo Extension (agent side, JavaScriptCore).");
    });
  },
});
