-- Lua demo extension: slash command.
minis.register_command({
  name = "ext-lua-status",
  handler = function()
    return "Lua runtime OK — this command executed in the vendored Lua 5.4 interpreter."
  end,
})
