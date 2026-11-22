import { Effect, Queue, Stream } from "effect";

interface SpawnExit {
  readonly status: number;
  readonly stderr: string;
}

interface Spawned {
  readonly exited: PromiseLike<SpawnExit>;
  readonly stop: () => void;
}

export type Spawn = (argv: readonly string[], onLine: (line: string) => void) => Spawned;

function exitMessage(argv: readonly string[], { status, stderr }: SpawnExit): string {
  const detail = stderr.trim();

  return `${argv[0]} exited with status ${status}${detail === "" ? "" : `: ${detail}`}`;
}

export function linesOf<E>(spawn: Spawn, fail: (cause: unknown) => E) {
  return (argv: readonly string[]): Stream.Stream<string, E> =>
    Stream.callback<string, E>((queue) =>
      Effect.acquireRelease(
        Effect.try({
          try: () =>
            spawn(argv, (line) => {
              Queue.offerUnsafe(queue, line);
            }),
          catch: fail,
        }),
        (spawned) => Effect.sync(() => spawned.stop()),
      ).pipe(
        Effect.flatMap((spawned) => Effect.promise(() => spawned.exited)),
        Effect.flatMap((exit) =>
          exit.status === 0
            ? Queue.end(queue)
            : Effect.fail(fail(new Error(exitMessage(argv, exit)))),
        ),
      ),
    );
}
