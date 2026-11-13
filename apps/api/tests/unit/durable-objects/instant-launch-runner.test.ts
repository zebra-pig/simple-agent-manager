import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  continueInstantSessionLaunch: vi.fn(),
  markTaskFailedIfNonTerminal: vi.fn(),
}));

vi.mock('../../../src/services/instant-session', () => ({
  continueInstantSessionLaunch: mocks.continueInstantSessionLaunch,
}));
vi.mock('../../../src/services/task-failure', () => ({
  markTaskFailedIfNonTerminal: mocks.markTaskFailedIfNonTerminal,
}));
vi.mock('drizzle-orm/d1', () => ({ drizzle: vi.fn(() => ({ db: true })) }));

import {
  INSTANT_LAUNCH_INTERRUPTED_MESSAGE,
  type InstantLaunchJob,
  InstantLaunchRunner,
} from '../../../src/durable-objects/instant-launch-runner';
import { scheduleInstantSessionLaunch } from '../../../src/services/instant-launch-schedule';

function memoryStorage() {
  const data = new Map<string, unknown>();
  let alarm: number | null = null;
  return {
    data,
    get alarm() {
      return alarm;
    },
    get: vi.fn(async (key: string) => data.get(key)),
    put: vi.fn(async (keyOrEntries: string | Record<string, unknown>, value?: unknown) => {
      if (typeof keyOrEntries === 'string') data.set(keyOrEntries, value);
      else for (const [k, v] of Object.entries(keyOrEntries)) data.set(k, v);
    }),
    deleteAll: vi.fn(async () => {
      data.clear();
    }),
    setAlarm: vi.fn(async (at: number) => {
      alarm = at;
    }),
  };
}

const job: InstantLaunchJob = {
  input: {
    taskId: 'task-1',
    project: { id: 'project-1', repository: 'owner/repo' } as never,
    userId: 'user-1',
    initialPrompt: 'hello',
    agentType: 'claude-code',
  },
  accepted: { taskId: 'task-1', nodeId: 'node-1', workspaceId: 'ws-1' } as never,
};

function runner() {
  const storage = memoryStorage();
  const env = { DATABASE: { d1: true } };
  const instance = new InstantLaunchRunner({ storage } as never, env as never);
  return { instance, storage, env };
}

describe('InstantLaunchRunner', () => {
  beforeEach(() => {
    mocks.continueInstantSessionLaunch.mockReset().mockResolvedValue(undefined);
    mocks.markTaskFailedIfNonTerminal.mockReset().mockResolvedValue(true);
  });

  it('stores the job and arms an immediate alarm instead of running in the caller', async () => {
    const { instance, storage } = runner();
    await instance.start(job);
    expect(storage.data.get('job')).toEqual(job);
    expect(storage.data.get('state')).toBe('pending');
    expect(storage.alarm).not.toBeNull();
    expect(mocks.continueInstantSessionLaunch).not.toHaveBeenCalled();
  });

  it('runs the launch once from the alarm and clears its state', async () => {
    const { instance, storage, env } = runner();
    await instance.start(job);
    await instance.alarm();
    expect(mocks.continueInstantSessionLaunch).toHaveBeenCalledTimes(1);
    expect(mocks.continueInstantSessionLaunch).toHaveBeenCalledWith(
      { db: true },
      env,
      job.input,
      job.accepted
    );
    expect(storage.data.size).toBe(0);
    await instance.alarm();
    expect(mocks.continueInstantSessionLaunch).toHaveBeenCalledTimes(1);
  });

  it('ignores a duplicate start so one task never launches two containers', async () => {
    const { instance, storage } = runner();
    await instance.start(job);
    await instance.start({ ...job, input: { ...job.input, initialPrompt: 'other' } });
    expect((storage.data.get('job') as InstantLaunchJob).input.initialPrompt).toBe('hello');
  });

  it('swallows a failed launch so the alarm is not retried', async () => {
    mocks.continueInstantSessionLaunch.mockRejectedValue(new Error('container failed'));
    const { instance, storage } = runner();
    await instance.start(job);
    await expect(instance.alarm()).resolves.toBeUndefined();
    expect(storage.data.size).toBe(0);
  });

  it('fails the task instead of relaunching when a previous run died mid-launch', async () => {
    const { instance, storage, env } = runner();
    await instance.start(job);
    storage.data.set('state', 'running');
    await instance.alarm();
    expect(mocks.continueInstantSessionLaunch).not.toHaveBeenCalled();
    expect(mocks.markTaskFailedIfNonTerminal).toHaveBeenCalledWith(
      env.DATABASE,
      'task-1',
      INSTANT_LAUNCH_INTERRUPTED_MESSAGE,
      undefined,
      { executionStep: 'launch_failed' }
    );
    expect(storage.data.size).toBe(0);
  });
});

describe('scheduleInstantSessionLaunch', () => {
  beforeEach(() => {
    mocks.continueInstantSessionLaunch.mockReset().mockResolvedValue(undefined);
  });

  function namespace() {
    const start = vi.fn(async () => undefined);
    const ns = {
      idFromName: vi.fn((name: string) => `id:${name}`),
      get: vi.fn(() => ({ start })),
    };
    return { ns, start };
  }

  it('hands the launch to the task runner object, not waitUntil, after the launch fence', async () => {
    const { ns, start } = namespace();
    const order: string[] = [];
    const assertLaunchAllowed = vi.fn(async () => {
      order.push('fence');
    });
    start.mockImplementation(async () => {
      order.push('start');
    });
    const waitUntil = vi.fn();

    await scheduleInstantSessionLaunch({
      db: {} as never,
      env: { INSTANT_LAUNCH_RUNNER: ns } as never,
      launch: { ...job.input, assertLaunchAllowed },
      accepted: job.accepted,
      waitUntil,
    });

    expect(order).toEqual(['fence', 'start']);
    expect(ns.idFromName).toHaveBeenCalledWith('task-1');
    const sent = start.mock.calls[0]![0] as InstantLaunchJob;
    expect(sent.input).not.toHaveProperty('assertLaunchAllowed');
    expect(sent).toEqual(job);
    expect(waitUntil).not.toHaveBeenCalled();
    expect(mocks.continueInstantSessionLaunch).not.toHaveBeenCalled();
  });

  it('does not hand off when the launch fence refuses', async () => {
    const { ns, start } = namespace();
    await expect(
      scheduleInstantSessionLaunch({
        db: {} as never,
        env: { INSTANT_LAUNCH_RUNNER: ns } as never,
        launch: { ...job.input, assertLaunchAllowed: async () => Promise.reject(new Error('no')) },
        accepted: job.accepted,
        waitUntil: vi.fn(),
      })
    ).rejects.toThrow('no');
    expect(start).not.toHaveBeenCalled();
  });

  it('keeps the waitUntil path when the binding is absent', async () => {
    const waitUntil = vi.fn();
    const onBackgroundError = vi.fn();
    mocks.continueInstantSessionLaunch.mockRejectedValue(new Error('boom'));
    await scheduleInstantSessionLaunch({
      db: {} as never,
      env: {} as never,
      launch: job.input,
      accepted: job.accepted,
      waitUntil,
      onBackgroundError,
    });
    expect(waitUntil).toHaveBeenCalledTimes(1);
    await waitUntil.mock.calls[0]![0];
    expect(onBackgroundError).toHaveBeenCalledWith(expect.objectContaining({ message: 'boom' }));
  });
});
