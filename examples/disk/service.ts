import { Effect, Schedule, host } from "gary:effect";

const refresh = Effect.gen(function* () {
  const result = yield* host.exec(["df", "-Pk", "/System/Volumes/Data"]);
  const fields = (result.stdout.trim().split("\n")[1] ?? "").split(/\s+/u);
  const total = Number(fields[1]);
  const used = Number(fields[2]);
  const free = Number(fields[3]);

  if (result.status !== 0 || !total) {
    return yield* host.log(`df failed: ${result.stderr.trim()}`);
  }

  yield* host.publish({
    usedPercent: Math.round((used / total) * 100),
    freeGB: Math.round(free / 1048576),
  });
}).pipe(Effect.catchTag("HostError", (error) => host.log(`df failed: ${error.message}`)));

export default {
  effect: Effect.repeat(refresh, Schedule.spaced("5 minutes")),

  methods: {
    refresh() {
      Effect.runFork(refresh);

      return "refreshing";
    },
  },
} satisfies Gary.Service;
