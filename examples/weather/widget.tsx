import { Effect, Schedule, Schema, Stream, fetch, host, settings, topic } from "gary:effect";

const Forecast = Schema.fromJsonString(
  Schema.Struct({
    current: Schema.Struct({ temperature_2m: Schema.Number, weather_code: Schema.Number }),
  }),
);

const symbols: [number[], string][] = [
  [[0], "sun.max"],
  [[1, 2], "cloud.sun"],
  [[3], "cloud"],
  [[45, 48], "cloud.fog"],
  [[51, 53, 55, 61, 63, 65, 80, 81, 82], "cloud.rain"],
  [[56, 57, 66, 67], "cloud.sleet"],
  [[71, 73, 75, 77, 85, 86], "cloud.snow"],
  [[95, 96, 99], "cloud.bolt.rain"],
];

const latitude = Number(settings.latitude ?? 52.37);
const longitude = Number(settings.longitude ?? 4.9);
const url = `https://api.open-meteo.com/v1/forecast?latitude=${latitude}&longitude=${longitude}&current=temperature_2m,weather_code`;

let weather: { temperature: number; symbol: string } | null = null;

const refresh = Effect.gen(function* () {
  const response = yield* fetch(url);

  if (response.status !== 200) {
    return yield* host.log(`weather request failed with status ${response.status}`);
  }

  const { current } = yield* Schema.decodeUnknownEffect(Forecast)(response.text);
  const symbol = symbols.find(([codes]) => codes.includes(current.weather_code))?.[1] ?? "cloud";

  weather = { temperature: Math.round(current.temperature_2m), symbol };
}).pipe(
  Effect.tapError((error) => host.log(`weather request failed: ${error.message}`)),
  Effect.ignore,
);

const unlocked = topic("session").pipe(
  Stream.map((session) => session.locked),
  Stream.changes,
  Stream.drop(1),
  Stream.filter((locked) => !locked),
);

export default {
  effect: Effect.gen(function* () {
    yield* Effect.forkScoped(Effect.repeat(refresh, Schedule.spaced("15 minutes")));
    yield* Stream.runForEach(unlocked, () => Effect.delay(refresh, "10 seconds"));
  }),

  render() {
    return (
      <row action="refresh" tooltip="Click to refresh">
        <icon key="icon" symbol={weather?.symbol ?? "cloud"} style="dim" />
        <text key="temperature">{weather ? `${weather.temperature}°` : "--°"}</text>
      </row>
    );
  },

  onAction(action) {
    if (action === "refresh") {
      return refresh;
    }
  },
} satisfies Gary.BarWidget;
