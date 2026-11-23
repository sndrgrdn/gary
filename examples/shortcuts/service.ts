import { Effect, Schema, Stream, host, settings } from "gary:effect";

const Shortcuts = Schema.Record(Schema.String, Schema.String);

const defaults = { "ctrl+alt+f": "com.apple.finder", "ctrl+alt+t": "com.apple.Terminal" };

export default {
  effect: Effect.gen(function* () {
    const shortcuts = yield* Schema.decodeUnknownEffect(Shortcuts)(settings.shortcuts ?? defaults);

    const open = (keys: string) =>
      host.apps
        .activate(shortcuts[keys])
        .pipe(Effect.catchTag("HostError", (error) => host.log(`${keys}: ${error.message}`)));

    yield* host.hotkeys(Object.keys(shortcuts)).pipe(Stream.runForEach(open));
  }),
} satisfies Gary.Service;
