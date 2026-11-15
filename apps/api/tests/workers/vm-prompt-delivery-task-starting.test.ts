/**
 * A follow-up sent while the task is still waiting for its VM is held, not failed.
 *
 * Production 2026-11-15: a user sent a task, then a second message right after to add to it.
 * The task was queued for node capacity, so no workspace row existed yet. The delivery resolver
 * read the missing workspace as "slept and torn down", started a sleep wake, and the wake refused
 * with `sleeping_snapshot_missing`: the follow-up failed and the chat showed "Wake failed".
 */
import { describe, expect, it } from 'vitest';

import { resolveVmPromptDeliveryTarget } from '../../src/services/vm-prompt-delivery-target';
import { testEnv } from './helpers/agent-message-channels';
import { seedInstallation, seedProject, seedTask, seedUser } from './helpers/seed-d1';

async function conversationWithTask(status: string) {
  const suffix = crypto.randomUUID();
  const userId = `starting-user-${suffix}`;
  const installationId = `starting-installation-${suffix}`;
  const projectId = `starting-project-${suffix}`;
  const chatSessionId = `starting-session-${suffix}`;
  await seedUser(userId);
  await seedInstallation(installationId, userId, { installationIdValue: `starting-${suffix}` });
  await seedProject(projectId, userId, installationId);
  await seedTask(`starting-task-${suffix}`, projectId, userId, { status, chatSessionId });
  return { projectId, chatSessionId };
}

function resolve(projectId: string, chatSessionId: string) {
  return resolveVmPromptDeliveryTarget(
    testEnv,
    projectId,
    chatSessionId,
    undefined,
    async () => null
  );
}

describe('prompt delivery before the task has a workspace', () => {
  it.each(['queued', 'delegated'])('holds a follow-up while the task is %s', async (status) => {
    const { projectId, chatSessionId } = await conversationWithTask(status);

    expect(await resolve(projectId, chatSessionId)).toEqual({
      kind: 'retry',
      reason: 'Task is still starting; no workspace yet',
    });
  });

  // Control: a task past `in_progress` with no workspace is not starting, so the resolver still
  // treats the missing runtime as a wake and reports the refusal.
  it('still asks recovery once the task no longer counts as starting', async () => {
    const { projectId, chatSessionId } = await conversationWithTask('in_progress');

    expect(await resolve(projectId, chatSessionId)).toMatchObject({
      kind: 'failed',
      reason: 'wake_refused',
      error: expect.stringContaining('sleeping_snapshot_missing'),
    });
  });
});
