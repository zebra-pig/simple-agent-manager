import type { drizzle } from 'drizzle-orm/d1';

import type * as schema from '../db/schema';
import type {
  InstantLaunchJob,
  InstantLaunchRunner,
} from '../durable-objects/instant-launch-runner';
import type { Env } from '../env';
import {
  type AcceptedInstantSession,
  continueInstantSessionLaunch,
  type LaunchInstantSessionInput,
} from './instant-session';

type Db = ReturnType<typeof drizzle<typeof schema>>;

/**
 * Hand an accepted Instant launch to its `InstantLaunchRunner` Durable Object, which runs it in
 * an alarm without the ~30 s `waitUntil()` cut-off that cancelled slow clones mid-launch.
 *
 * `assertLaunchAllowed` cannot cross the Durable Object boundary, so it runs here, before the
 * hand-off; `continueInstantSessionLaunch` checked it once at its start, which is the same point.
 * Installs without the binding (local tests, older generated configs) keep the previous
 * `waitUntil` path.
 */
export async function scheduleInstantSessionLaunch(input: {
  db: Db;
  env: Env;
  launch: LaunchInstantSessionInput;
  accepted: AcceptedInstantSession;
  waitUntil: (promise: Promise<unknown>) => void;
  onBackgroundError?: (error: unknown) => void;
}): Promise<void> {
  const { db, env, launch, accepted, waitUntil, onBackgroundError } = input;
  const namespace = env.INSTANT_LAUNCH_RUNNER;
  if (!namespace) {
    waitUntil(
      continueInstantSessionLaunch(db, env, launch, accepted).catch((error: unknown) =>
        onBackgroundError?.(error)
      )
    );
    return;
  }
  await launch.assertLaunchAllowed?.();
  const serializable: InstantLaunchJob['input'] = { ...launch };
  delete (serializable as Partial<LaunchInstantSessionInput>).assertLaunchAllowed;
  const job: InstantLaunchJob = { input: serializable, accepted };
  const stub = namespace.get(
    namespace.idFromName(accepted.taskId)
  ) as DurableObjectStub<InstantLaunchRunner>;
  await stub.start(job);
}
