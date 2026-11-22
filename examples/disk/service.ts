async function refresh() {
  const result = await host.exec(["df", "-Pk", "/System/Volumes/Data"]);
  const fields = (result.stdout.trim().split("\n")[1] ?? "").split(/\s+/u);
  const total = Number(fields[1]);
  const used = Number(fields[2]);
  const free = Number(fields[3]);

  if (result.status !== 0 || !total) {
    return host.log(`df failed: ${result.stderr.trim()}`);
  }

  host.publish({
    usedPercent: Math.round((used / total) * 100),
    freeGB: Math.round(free / 1048576),
  });
}

refresh();

setInterval(refresh, 5 * 60_000);

export default {
  methods: {
    refresh() {
      refresh();

      return "refreshing";
    },
  },
} satisfies Gary.Service;
