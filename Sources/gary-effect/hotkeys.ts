import { Effect, Queue, Stream } from "effect";

interface Listening {
  readonly stop: () => void;
}

export type Listen = (keys: readonly string[], onPress: (keys: string) => void) => Listening;

export function pressesOf<E>(listen: Listen, fail: (cause: unknown) => E) {
  return (keys: readonly string[]): Stream.Stream<string, E> =>
    Stream.callback<string, E>((queue) =>
      Effect.acquireRelease(
        Effect.try({
          try: () =>
            listen(keys, (pressed) => {
              Queue.offerUnsafe(queue, pressed);
            }),
          catch: fail,
        }),
        (listening) => Effect.sync(() => listening.stop()),
      ),
    );
}
