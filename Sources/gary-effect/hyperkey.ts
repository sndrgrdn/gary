import { Effect, type Scope } from "effect";

export type Hold<O> = (options: O | undefined) => { readonly stop: () => void };

export function heldOf<O, E>(hold: Hold<O>, fail: (cause: unknown) => E) {
  return (options?: O): Effect.Effect<void, E, Scope.Scope> =>
    Effect.asVoid(
      Effect.acquireRelease(Effect.try({ try: () => hold(options), catch: fail }), (held) =>
        Effect.sync(() => held.stop()),
      ),
    );
}
