import "./text-encoder";
import "./text-decoder";
import { clockOf } from "./clock";
import { type Spawn, linesOf } from "./spawn";
import {
  Cache,
  Cause,
  Clock,
  Context,
  Data,
  Deferred,
  Duration,
  Effect,
  Exit,
  Fiber,
  Layer,
  Option,
  Predicate,
  PubSub,
  Queue,
  Ref,
  Schedule,
  Scheduler,
  Schema,
  Scope,
  Semaphore,
  Stream,
  SubscriptionRef,
  pipe,
} from "effect";

type Json = null | boolean | number | string | readonly Json[] | { readonly [key: string]: Json };

type HostResult = Json | undefined | PromiseLike<Json | undefined>;

type HostFunction = (...args: Json[]) => HostResult;

interface Host {
  readonly [name: string]: HostFunction | Host;
}

type Lifted = (...args: Json[]) => Effect.Effect<Json | undefined, HostError>;

type LineStream = (argv: readonly string[]) => Stream.Stream<string, HostError>;

interface LiftedHost {
  [name: string]: Lifted | LiftedHost | LineStream;
}

interface Env {
  readonly host: Host;
  readonly spawn: Spawn | undefined;
  readonly fetch: HostFunction | undefined;
  readonly setTimeout: (callback: () => void, ms: number) => number;
  readonly clearTimeout: (id: number) => void;
  readonly settings: { readonly [key: string]: Json };
}

interface TopicEvent {
  readonly topic: string;
  readonly value: Json;
}

const ignore = (): void => undefined;

class HostError extends Data.TaggedError("HostError")<{ readonly message: string }> {}

function hostError(cause: unknown): HostError {
  return new HostError({
    message: Predicate.hasProperty(cause, "message") ? String(cause.message) : String(cause),
  });
}

function lift(run: HostFunction, owner?: Host): Lifted {
  return (...args) =>
    Effect.try({ try: () => run.apply(owner, args), catch: hostError }).pipe(
      Effect.flatMap((result) =>
        Predicate.isPromiseLike(result)
          ? Effect.tryPromise({ try: () => Promise.resolve(result), catch: hostError })
          : Effect.succeed(result),
      ),
    );
}

function mirror(host: Host): LiftedHost {
  const lifted: LiftedHost = {};

  for (const [name, member] of Object.entries(host)) {
    lifted[name] = Predicate.isFunction(member) ? lift(member, host) : mirror(member);
  }

  return lifted;
}

function hostOf(env: Env): LiftedHost {
  const lifted = mirror(env.host);

  if (env.spawn !== undefined) {
    lifted.spawn = linesOf(env.spawn, hostError);
  }

  return lifted;
}

function servicesOf(env: Env) {
  const scheduler = new Scheduler.MixedScheduler("async", (task) => {
    const id = env.setTimeout(task, 0);

    return () => env.clearTimeout(id);
  });

  return Context.make(Scheduler.Scheduler, scheduler).pipe(Context.add(Clock.Clock, clockOf(env)));
}

function asyncRunners(services: ReturnType<typeof servicesOf>, scope: Scope.Scope) {
  const attach = (options?: Effect.RunOptions): Effect.RunOptions => ({
    ...options,
    onFiberStart: (fiber) => {
      Fiber.runIn(fiber, scope);
      options?.onFiberStart?.(fiber);
    },
  });

  return {
    runForkWith:
      <R>(context: Context.Context<R>) =>
      <A, E>(effect: Effect.Effect<A, E, R>, options?: Effect.RunOptions) =>
        Effect.runForkWith(Context.merge(services, context))(effect, attach(options)),
    runCallbackWith:
      <R>(context: Context.Context<R>) =>
      <A, E>(
        effect: Effect.Effect<A, E, R>,
        options?: Effect.RunOptions & { readonly onExit: (exit: Exit.Exit<A, E>) => void },
      ) =>
        Effect.runCallbackWith(Context.merge(services, context))(effect, {
          ...attach(options),
          onExit: options?.onExit ?? ignore,
        }),
    runPromiseWith:
      <R>(context: Context.Context<R>) =>
      <A, E>(effect: Effect.Effect<A, E, R>, options?: Effect.RunOptions) =>
        Effect.runPromiseWith(Context.merge(services, context))(effect, attach(options)),
    runPromiseExitWith:
      <R>(context: Context.Context<R>) =>
      <A, E>(effect: Effect.Effect<A, E, R>, options?: Effect.RunOptions) =>
        Effect.runPromiseExitWith(Context.merge(services, context))(effect, attach(options)),
  };
}

function bind(services: ReturnType<typeof servicesOf>, scope: Scope.Scope) {
  const { runForkWith, runCallbackWith, runPromiseWith, runPromiseExitWith } = asyncRunners(
    services,
    scope,
  );

  const runSyncWith = <R>(context: Context.Context<R>) =>
    Effect.runSyncWith(Context.merge(services, context));

  const runSyncExitWith = <R>(context: Context.Context<R>) =>
    Effect.runSyncExitWith(Context.merge(services, context));

  return {
    ...Effect,
    runForkWith,
    runFork: runForkWith(Context.empty()),
    runCallbackWith,
    runCallback: runCallbackWith(Context.empty()),
    runPromiseWith,
    runPromise: runPromiseWith(Context.empty()),
    runPromiseExitWith,
    runPromiseExit: runPromiseExitWith(Context.empty()),
    runSyncWith,
    runSync: runSyncWith(Context.empty()),
    runSyncExitWith,
    runSyncExit: runSyncExitWith(Context.empty()),
  };
}

function topicsOf(run: ReturnType<typeof bind>) {
  const refs = new Map<string, SubscriptionRef.SubscriptionRef<Option.Option<Json>>>();

  const ref = (name: string) => {
    const existing = refs.get(name);

    if (existing !== undefined) {
      return existing;
    }

    const created = run.runSync(SubscriptionRef.make(Option.none<Json>()));
    refs.set(name, created);

    return created;
  };

  return {
    stream: (name: string) =>
      SubscriptionRef.changes(ref(name)).pipe(
        Stream.filter(Option.isSome),
        Stream.map((some) => some.value),
      ),
    receive: (event: TopicEvent) =>
      run.runSync(SubscriptionRef.set(ref(event.topic), Option.some(event.value))),
  };
}

function exportsOf(
  env: Env,
  bound: ReturnType<typeof bind>,
  topic: (name: string) => Stream.Stream<Json>,
) {
  return {
    Cache,
    Cause,
    Context,
    Data,
    Deferred,
    Duration,
    Effect: bound,
    Exit,
    Fiber,
    Layer,
    Option,
    PubSub,
    Queue,
    Ref,
    Schedule,
    Schema,
    Scope,
    Semaphore,
    Stream,
    SubscriptionRef,
    pipe,
    host: hostOf(env),
    fetch: env.fetch === undefined ? undefined : lift(env.fetch),
    settings: env.settings,
    topic,
  };
}

function messageOf(cause: Cause.Cause<unknown>): string {
  const error = Cause.squash(cause);

  return Predicate.hasProperty(error, "message") ? String(error.message) : String(error);
}

export function forPlugin(env: Env) {
  const services = servicesOf(env);
  const scope = Scope.makeUnsafe();
  const bound = bind(services, scope);
  const topics = topicsOf(bound);

  const failOn = (what: string) => (exit: Exit.Exit<unknown, unknown>) => {
    if (Exit.isFailure(exit) && !Cause.hasInterruptsOnly(exit.cause)) {
      env.setTimeout(() => {
        throw new Error(`${what}: ${Cause.pretty(exit.cause)}`);
      }, 0);
    }
  };

  return {
    exports: exportsOf(env, bound, topics.stream),
    receive: topics.receive,
    isEffect: Effect.isEffect,
    start(program: Effect.Effect<void, unknown, Scope.Scope>) {
      if (!Effect.isEffect(program)) {
        throw new TypeError("the default export's effect is not an Effect");
      }

      bound.runFork(Scope.provide(program, scope)).addObserver(failOn("the effect stopped"));
    },
    run(handler: string, program: Effect.Effect<unknown, unknown>) {
      bound.runFork(program).addObserver(failOn(`the effect that ${handler} returned failed`));
    },
    promise(program: Effect.Effect<Json | undefined, unknown>): Promise<Json | undefined> {
      return bound
        .runPromiseExit(program)
        .then((exit) =>
          Exit.isSuccess(exit) ? exit.value : Promise.reject(new Error(messageOf(exit.cause))),
        );
    },
    close() {
      Effect.runForkWith(services)(Scope.close(scope, Exit.void));
    },
  };
}
