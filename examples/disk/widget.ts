type Disk = { usedPercent: number; freeGB: number };

let showFree = false;

function parseDisk(value: Gary.Json | undefined): Disk | undefined {
  if (!(value instanceof Object) || Array.isArray(value)) {
    return undefined;
  }

  const usedPercent = Number(value.usedPercent);
  const freeGB = Number(value.freeGB);

  return Number.isFinite(usedPercent) && Number.isFinite(freeGB)
    ? { usedPercent, freeGB }
    : undefined;
}

module.exports = {
  render(state) {
    const disk = parseDisk(state["example.disk"]);

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
