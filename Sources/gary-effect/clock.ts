import { Clock, Duration, Effect } from "effect";

interface Timers {
  readonly setTimeout: (callback: () => void, ms: number) => number;
  readonly clearTimeout: (id: number) => void;
}

export function clockOf(env: Timers): Clock.Clock {
  const base = Effect.runSync(Clock.clockWith(Effect.succeed));

  const sleep = (millis: number): Effect.Effect<void> => {
    if (millis <= 0) {
      return Effect.yieldNow;
    }

    if (!Number.isFinite(millis)) {
      return Effect.never;
    }

    return Effect.callback<void>((resume) => {
      const id = env.setTimeout(() => resume(Effect.void), millis);

      return Effect.sync(() => env.clearTimeout(id));
    });
  };

  return {
    currentTimeMillisUnsafe: () => base.currentTimeMillisUnsafe(),
    currentTimeMillis: base.currentTimeMillis,
    currentTimeNanosUnsafe: () => base.currentTimeNanosUnsafe(),
    currentTimeNanos: base.currentTimeNanos,
    monotonicTimeNanosUnsafe: () => base.monotonicTimeNanosUnsafe(),
    monotonicTimeNanos: base.monotonicTimeNanos,
    sleep: (duration) => sleep(Duration.toMillis(duration)),
  };
}
