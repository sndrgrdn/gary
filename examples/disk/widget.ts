type Disk = { usedPercent: number; freeGB: number };

let showFree = false;

module.exports = {
  render(state) {
    const disk = state["example.disk"] as Disk | undefined;

    if (!disk) {
      return { type: "text", text: "disk …", style: "dim" };
    }

    return {
      type: "row",
      action: "toggle",
      children: [
        {
          type: "icon",
          key: "icon",
          symbol: "internaldrive",
          style: disk.usedPercent > 90 ? "bad" : "dim",
        },
        {
          type: "text",
          key: "value",
          text: showFree ? `${disk.freeGB} GB free` : `${disk.usedPercent}%`,
        },
      ],
    };
  },

  onAction(action) {
    if (action === "toggle") {
      showFree = !showFree;
    }
  },
} satisfies Gary.BarWidget;
