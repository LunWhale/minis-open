// Demo extension: event hook.
// Subscribes to agent lifecycle events. Events fire as the parent agent runs.
minis.on("agent_start", function (event) {
  minis.log("[demo] agent started", event && event.sessionId || "");
});
