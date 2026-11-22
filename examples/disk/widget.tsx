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

export default {
  render(state) {
    const disk = parseDisk(state["example.disk"]);

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
