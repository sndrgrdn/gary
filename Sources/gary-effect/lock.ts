import { Effect, type Scope } from "effect";

interface FileLock {
  readonly release: () => void;
}

export type LockFile = (path: string) => PromiseLike<FileLock>;

export function lockedOf<E>(lockFile: LockFile, fail: (cause: unknown) => E) {
  return (path: string): Effect.Effect<void, E, Scope.Scope> =>
    Effect.asVoid(
      Effect.acquireRelease(
        Effect.tryPromise({ try: () => Promise.resolve(lockFile(path)), catch: fail }),
        (lock) => Effect.sync(() => lock.release()),
      ),
    );
}
