// Request-interceptor demo: add a header to outgoing AI model requests.
//
// `minis.api.request.intercept(handler)` registers a hook that runs right
// before a model request leaves the app. The handler receives
//
//   { provider, model, sessionId?, url, method, headers, body? }
//
// and may either mutate that object in place, return a patch object, or
// return a Promise of either. Patch keys: url, method, headers, body (string),
// bodyJSON (object — serialized to JSON for you).
//
// Requires the "requests" permission in manifest.json. The first intercepted
// request asks the user once; the grant persists across launches.
//
// Registration happens at script load (top level), so the interceptor is
// armed before the first model request of the session.

var interceptorId = minis.api.request.intercept({
  name: "demo-header-injector",
  handler: function (req) {
    // Read settings live on every request so the ⚙️ page applies instantly.
    if (minis.api.settings.get("enabled") === false) return null;

    var wanted = minis.api.settings.get("provider") || "any";
    var verbose = minis.api.settings.get("verbose") !== false;
    if (wanted !== "any" && req.provider !== wanted) {
      if (verbose) {
        minis.log("[request-interceptor] skip", req.provider, "(only " + wanted + ")");
      }
      return null;
    }

    var tag = minis.api.settings.get("tag");
    if (!tag) tag = "minis-open";

    if (verbose) {
      minis.log("[request-interceptor] intercepted", req.provider,
                req.method, req.url, "-> X-Plugin-Tag:" + tag);
    }

    return {
      headers: {
        // Only new/overwritten headers need to be listed; the rest of the
        // request (url, method, body, existing headers) is preserved.
        "X-Plugin-Tag": tag,
      },
    };
  },
});

minis.on("agent_start", function (event) {
  minis.log("[request-interceptor] armed (id=" + interceptorId + ")",
            "session=" + ((event && event.sessionId) || "-"));
});

minis.on("agent_end", function (event) {
  minis.log("[request-interceptor] agent_end round=" + ((event && event.round) || "?"));
});
