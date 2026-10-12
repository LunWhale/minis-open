// Demo extension: event hook.
// Subscribes to agent lifecycle + tool events. minis.log is variadic —
// pass any mix of strings, numbers, objects, arrays (each is stringified
// and joined with spaces).
minis.on("agent_start", function (event) {
  minis.log("[demo] agent_start", (event && event.sessionId) || "");
});

minis.on("agent_end", function (event) {
  minis.log("[demo] agent_end round=" + ((event && event.round) || "?"));
});

minis.on("tool_call", function (event) {
  minis.log("[demo] tool_call", event && event.tool,
            "argsKeys", event && event.args ? Object.keys(event.args) : []);
});

minis.on("tool_result", function (event) {
  minis.log("[demo] tool_result", event && event.tool,
            "success=" + (event && event.success));
});
