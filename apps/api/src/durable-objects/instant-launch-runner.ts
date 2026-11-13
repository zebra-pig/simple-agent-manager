import { DurableObject } from 'cloudflare:workers';
import { drizzle } from 'drizzle-orm/d1';

import * as schema from '../db/schema';
import type { Env } from '../env';
import { log } from '../lib/logger';
import {
  type AcceptedInstantSession,
  continueInstantSessionLaunch,
  type LaunchInstantSessionInput,
} from '../services/instant-session';
import { markTaskFailedIfNonTerminal } from '../services/task-failure';

/**
 * The serializable part of an accepted Instant launch. `assertLaunchAllowed` is a
 * closure, so the caller runs it before handing off (see `scheduleInstantSessionLaunch`);
 * `continueInstantSessionLaunch` only ever consulted it once, at its start.
 */
export interface InstantLaunchJob {
  input: Omit<LaunchInstantSessionInput, 'assertLaunchAllowed'>;
  accepted: AcceptedInstantSession;
}

const JOB_KEY = 'job';
const STATE_KEY = 'state';
type JobState = 'pending' | 'running';

export const INSTANT_LAUNCH_INTERRUPTED_MESSAGE =
  'Instant session launch was interrupted before the agent started. Retry the chat.';

/**
 * Runs the slow half of an Instant (cf-container) launch — container start, repository clone,
 * agent session start — outside the request that accepted it.
 *
 * It used to run in the Worker's `ctx.waitUntil()`, which Cloudflare cancels about 30 s after
 * the response is sent. A repository whose clone alone takes ~30 s (production 2026-11-13,
 * log: "waitUntil() tasks did not complete within the allowed time ... cancelled") lost the
 * launch after the workspace was created and before the agent started, with nothing recorded:
 * the task stayed `queued` until the stuck-task sweep. A Durable Object alarm has no such
 * cut-off. One object per task id; the job runs at most once.
 */
export class InstantLaunchRunner extends DurableObject<Env> {
  async start(job: InstantLaunchJob): Promise<void> {
    if (await this.ctx.storage.get<InstantLaunchJob>(JOB_KEY)) return;
    await this.ctx.storage.put({ [JOB_KEY]: job, [STATE_KEY]: 'pending' satisfies JobState });
    await this.ctx.storage.setAlarm(Date.now());
  }

  override async alarm(): Promise<void> {
    const job = await this.ctx.storage.get<InstantLaunchJob>(JOB_KEY);
    if (!job) return;
    const taskId = job.input.taskId;
    const state = await this.ctx.storage.get<JobState>(STATE_KEY);
    if (state === 'running') {
      // A previous run died mid-launch (eviction, deploy). The launch is not resumable from
      // here, so record a terminal failure instead of leaving the task queued, and never
      // re-run it: a second launch would race the first one's partially created resources.
      log.error('instant_launch_runner.interrupted', { taskId });
      await markTaskFailedIfNonTerminal(
        this.env.DATABASE,
        taskId,
        INSTANT_LAUNCH_INTERRUPTED_MESSAGE,
        undefined,
        { executionStep: 'launch_failed' }
      ).catch((error: unknown) =>
        log.error('instant_launch_runner.interrupted_mark_failed', { taskId, error: String(error) })
      );
      await this.ctx.storage.deleteAll();
      return;
    }
    await this.ctx.storage.put(STATE_KEY, 'running' satisfies JobState);
    try {
      await continueInstantSessionLaunch(
        drizzle(this.env.DATABASE, { schema }),
        this.env,
        job.input,
        job.accepted
      );
    } catch (error) {
      // continueInstantSessionLaunch persists the failed task/session before rejecting.
      // Swallow so the alarm is not retried: a retry would launch a second container.
      log.error('instant_launch_runner.launch_failed', { taskId, error: String(error) });
    } finally {
      await this.ctx.storage.deleteAll();
    }
  }
}
