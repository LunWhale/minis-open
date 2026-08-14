// Demo extension: agent tool that broadcasts to the extension's UI widget
// via minis.api.ui.postMessage. The rendered widget (ui/widget.html) receives
// it through window.minisBridge.onMessage and displays it.
minis.registerTool({
  name: "notify_widget",
  description: "Sends a message to the Demo Extension's UI widget (rendered in the Extension Widgets panel). Demonstrates agent→widget messaging.",
  parameters: {},
  execute: function (args) {
    var text = (args && args.text) || "Hello from the agent tool!";
    if (minis.api && minis.api.ui && minis.api.ui.postMessage) {
      minis.api.ui.postMessage({ type: "demo:notify", text: text, from: "agent" });
      return "Sent to widget: " + text;
    }
    return "Error: minis.api.ui.postMessage unavailable";
  },
});
