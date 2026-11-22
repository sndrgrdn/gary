let load: string | null = null;

async function refresh() {
  const result = await host.exec(["sysctl", "-n", "vm.loadavg"]);
  const averages = result.stdout.replaceAll(/[{}]/gu, "").trim().split(/\s+/u);
  load = result.status === 0 ? averages[0] : null;
}

refresh();

setInterval(refresh, 30_000);

export default {
  render() {
    return (
      <row action="refresh">
        <icon key="icon" symbol="cpu" style="dim" />
        <text key="load">{load ?? "…"}</text>
      </row>
    );
  },

  onAction(action) {
    if (action === "refresh") {
      refresh();
    }
  },
} satisfies Gary.BarWidget;
