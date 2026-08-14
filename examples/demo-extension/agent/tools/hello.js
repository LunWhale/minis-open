// Demo extension: agent tool.
// Registered via minis.registerTool. The `execute` function receives args
// (JSON object) and must return a string (or throw/return an object with
// {error: "..."}).
minis.registerTool({
  name: "hello_world",
  description: "Returns a greeting. Demonstrates a minimal extension tool.",
  parameters: {},
  execute: function (args) {
    const who = (args && args.name) || "world";
    return "Hello, " + who + "! This tool ran from the Demo Extension (agent side, JavaScriptCore).";
  },
});
