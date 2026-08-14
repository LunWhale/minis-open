-- Lua demo extension: agent tool.
-- Registered via minis.register_tool. The `execute` function receives the
-- args table and must return a string.
minis.register_tool({
  name = "lua_greet",
  description = "Returns a greeting computed in Lua.",
  execute = function(args)
    local who = "world"
    if args and args.name then who = args.name end
    return "Hello, " .. who .. "! This tool ran from Lua (vendored Lua 5.4 runtime)."
  end,
})
