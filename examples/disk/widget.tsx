let showFree = false;

export default {
  render(state) {
    const disk = state["example.disk"];

    if (!disk) {
      return <text style="dim">disk …</text>;
    }

    return (
      <row action="toggle">
        <icon key="icon" symbol="internaldrive" style={disk.usedPercent > 90 ? "bad" : "dim"} />
        <text key="value">{showFree ? `${disk.freeGB} GB free` : `${disk.usedPercent}%`}</text>
      </row>
    );
  },

  onAction(action) {
    if (action === "toggle") {
      showFree = !showFree;
    }
  },
} satisfies Gary.BarWidget;
