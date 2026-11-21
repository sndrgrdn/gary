module.exports = {
  render(state) {
    const all = state.workspaces;
    const mine = all && state.display && all.displays.find((d) => d.id === state.display.id);
    return {
      type: "row",
      children: (mine ? mine.workspaces : []).map((w) => ({
        type: "text",
        key: w.name,
        text: w.name,
        style: w.focused ? "active" : w.visible ? "bright" : "dim",
        action: all.source === "dinky" ? w.name : undefined,
      })),
    };
  },
  onAction(name) {
    host.dinky("workspace " + name);
  },
};
