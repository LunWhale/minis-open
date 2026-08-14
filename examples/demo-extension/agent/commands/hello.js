// Demo extension: slash command.
// Registered via minis.registerCommand({ name, handler }). The handler is
// invoked when the user types /ext-hello in the chat.
minis.registerCommand({
  name: "ext-hello",
  handler: function () {
    return "Hello from the Demo Extension command!";
  },
});
