let load: string | null = null;

function refresh() {
  host.exec(["sysctl", "-n", "vm.loadavg"], (result) => {
    const averages = result.stdout.replace(/[{}]/g, "").trim().split(/\s+/);
    load = result.status === 0 ? averages[0] : null;
  });
}

refresh();
setInterval(refresh, 30_000);

module.exports = {
  render() {
    return {
      type: "row",
      action: "refresh",
      children: [
        { type: "icon", key: "icon", symbol: "cpu", style: "dim" },
        { type: "text", key: "load", text: load ?? "…" },
      ],
    };
  },

  onAction(action) {
    if (action === "refresh") refresh();
  },
} satisfies Gary.BarWidget;
