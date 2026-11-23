import { Effect, Queue, Stream } from "effect";

interface Listening {
  readonly stop: () => void;
}

export type Listen<A, T> = (argument: A, onEvent: (value: T) => void) => Listening;

export function eventsOf<A, T, E>(listen: Listen<A, T>, fail: (cause: unknown) => E) {
  return (argument: A): Stream.Stream<T, E> =>
    Stream.callback<T, E>((queue) =>
      Effect.acquireRelease(
        Effect.try({
          try: () =>
            listen(argument, (value) => {
              Queue.offerUnsafe(queue, value);
            }),
          catch: fail,
        }),
        (listening) => Effect.sync(() => listening.stop()),
      ),
    );
}
