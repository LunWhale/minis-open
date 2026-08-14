-- Lua demo extension: slash command that exercises the real Lua → native
-- bridges: minis.api.shell (runs in the sandbox via ISHExecutionCoordinator)
-- and minis.api.permission. Demonstrates that Lua extensions get the full
-- host bridge, not a stub.
minis.register_command({
  name = "ext-lua-status",
  handler = function()
    local runtime = "Lua runtime OK (vendored Lua 5.4 interpreter)"
    if minis.api and minis.api.shell then
      local out = minis.api.shell("uname -s -m", { timeout = 15 })
      if out and out ~= "" and not out:find("^Error") then
        runtime = runtime .. "\nSandbox: " .. out
      else
        runtime = runtime .. "\n(api.shell unavailable: " .. tostring(out) .. ")"
      end
    end
    return runtime
  end,
})
