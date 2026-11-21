import { readFileSync } from 'node:fs';

import type { OperationContext } from '@simple-agent-manager/operations';
import { samChatDeliveryGet, samChatSend } from '@simple-agent-manager/operations';
import type { AgentMailboxMessage } from '@simple-agent-manager/shared';
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import * as schema from '../../../src/db/schema';
import type { Env } from '../../../src/env';
import { createOperationPorts } from '../../../src/operation-ports';
import { sessionAccessFromGetSession } from '../../helpers/session-access-mock';
import { createSchemaTables, createSqliteD1 } from '../../helpers/sqlite-d1';

const mocks = vi.hoisted(() => ({
  send: vi.fn(),
  getSession: vi.fn(),
  getMailboxMessage: vi.fn(),
}));
vi.mock('../../../src/services/send-chat', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../src/services/send-chat')>()),
  sendChat: mocks.send,
}));
vi.mock('../../../src/services/project-data', () => ({
  getSession: mocks.getSession,
  getSessionAccess: (...args: [unknown, string, string, string]) =>
    sessionAccessFromGetSession(mocks.getSession)(...args),
  getSessionWithAccessGrants: async (
    env: unknown,
    projectId: string,
    sessionId: string,
    userId: string
  ) => ({
    ...(await sessionAccessFromGetSession(mocks.getSession)(env, projectId, sessionId, userId)),
    grants: [],
  }),
  getMailboxMessage: mocks.getMailboxMessage,
  recordActivityEvent: vi.fn().mockResolvedValue(undefined),
}));

/** A durable inbox row as ProjectData returns it, after the steer lane ran. */
function row(overrides: Partial<AgentMailboxMessage> = {}): AgentMailboxMessage {
  return {
    id: 'delivery-1',
    targetSessionId: 'chat',
    sourceTaskId: null,
    senderType: 'human',
    senderId: 'owner',
    messageClass: 'deliver',
    deliveryState: 'acked',
    content: 'secret prompt text',
    metadata: null,
    ackRequired: false,
    ackTimeoutMs: null,
    deliveryAttempts: 1,
    lastDeliveryAt: 10,
    expiresAt: 100,
    createdAt: 1,
    deliveredAt: 10,
    ackedAt: 10,
    sourceKind: 'user_followup',
    promptMessageId: 'message-1',
    nextAttemptAt: null,
    lastError: null,
    terminalReason: null,
    attemptId: null,
    attemptStartedAt: null,
    runtimeIdentity: 'runtime',
    receiptState: null,
    receiptRuntimeIdentity: null,
    receiptCheckedAt: null,
    acceptedAt: 10,
    adapterProtocolVersion: 1,
    receiptSupported: null,
    deliveryIntent: 'steer',
    steerOutcome: 'steered',
    steerReason: null,
    ...overrides,
  };
}

/** What the steer lane does with a running, steering-capable turn. */
const STEERED = row();
/** What it does when the VM's receipt is `not_consumed` or SAM never reached a turn. */
const fellBack = (reason: string) =>
  row({
    deliveryIntent: 'queue',
    deliveryState: 'queued',
    steerOutcome: 'queued_fallback',
    steerReason: reason,
  });

describe('sam_chat_send delivery intent', () => {
  let sqlite: Database.Database;
  let env: Env;
  function ctx(idempotencyKey?: string): OperationContext {
    return {
      env,
      ports: createOperationPorts(env),
      actor: {
        userId: 'owner',
        via: 'connector',
        clientName: 'Claude',
        scopes: new Set(['sam.read', 'sam.write']),
      },
      requestId: 'test',
      ...(idempotencyKey ? { idempotencyKey } : {}),
      execCtx: { waitUntil: vi.fn() } as unknown as ExecutionContext,
    };
  }
  const send = (input: Record<string, unknown>, c = ctx()) =>
    samChatSend.run(c, {
      projectId: 'project',
      sessionId: 'chat',
      content: 'Stop: use the v2 API instead',
      ...input,
    } as never);
  const sentIntents = () =>
    mocks.send.mock.calls.map((call) => (call[4] as { deliveryIntent?: string }).deliveryIntent);

  beforeEach(() => {
    vi.clearAllMocks();
    sqlite = new Database(':memory:');
    createSchemaTables(sqlite, [
      schema.users,
      schema.projects,
      schema.projectMembers,
      schema.tasks,
      schema.sessionSummaries,
      schema.platformSettings,
    ]);
    for (const file of ['0191_connector_execution.sql', '0189_cli_operation_receipts.sql'])
      sqlite.exec(
        readFileSync(new URL(`../../../src/db/migrations/${file}`, import.meta.url), 'utf8')
      );
    sqlite.prepare("INSERT INTO users (id,name,email) VALUES ('owner','Owner','o@x.test')").run();
    sqlite.prepare("INSERT INTO projects (id,name) VALUES ('project','project')").run();
    sqlite
      .prepare(
        "INSERT INTO project_members (project_id,user_id,role,status) VALUES ('project','owner','owner','active')"
      )
      .run();
    sqlite
      .prepare(
        "INSERT INTO session_summaries (id,project_id,created_by_user_id,updated_at) VALUES ('chat','project','owner',1)"
      )
      .run();
    mocks.getSession.mockImplementation(
      async (_env: unknown, projectId: string, sessionId: string) =>
        projectId === 'project' && sessionId === 'chat'
          ? { id: sessionId, createdByUserId: 'owner' }
          : null
    );
    // The real sendChat accepts into the durable inbox and answers `queued` for either intent.
    mocks.send.mockImplementation(
      async (_env, _user, _project, _session, body: { deliveryIntent?: string }) => ({
        accepted: true,
        status: 'queued',
        deliveryIntent: body.deliveryIntent ?? 'queue',
        deliveryId: 'delivery-1',
        messageId: 'message-1',
      })
    );
    env = {
      DATABASE: createSqliteD1(sqlite),
      BASE_DOMAIN: 'example.com',
      DURABLE_PROMPT_DELIVERY_ENABLED: 'true',
      MAILBOX_MESSAGE_MAX_LENGTH: '100',
    } as unknown as Env;
  });
  afterEach(() => sqlite.close());

  it('auto (the default) steers into a running steering-capable turn', async () => {
    mocks.getMailboxMessage.mockResolvedValue(STEERED);
    const result = await send({});
    expect(sentIntents()).toEqual(['steer']);
    expect(result).toMatchObject({
      accepted: true,
      status: 'queued',
      deliveryIntent: 'auto',
      deliveredAs: 'steer',
      deliveryId: 'delivery-1',
      messageId: 'message-1',
    });
    expect(result).not.toHaveProperty('fallbackReason');
    expect(mocks.getMailboxMessage).toHaveBeenCalledWith(env, 'project', 'delivery-1');
  });

  it.each([
    ['session_not_awake', 'not_running'],
    ['no_running_turn', 'not_running'],
    ['runtime_steering_unsupported', 'runtime_steering_unsupported'],
    ['adapter_does_not_advertise_steering', 'runtime_steering_unsupported'],
    ['checkpoint_in_progress', 'steering_unavailable'],
  ])('auto falls back to the queue when the steer lane reports %s', async (detail, reason) => {
    mocks.getMailboxMessage.mockResolvedValue(fellBack(detail));
    const result = await send({});
    expect(result).toMatchObject({
      deliveryIntent: 'auto',
      deliveredAs: 'queue',
      fallbackReason: reason,
      fallbackDetail: detail,
      deliveryId: 'delivery-1',
    });
  });

  it('auto queues too-long content without trying a steer and never fails', async () => {
    const result = await send({ content: 'x'.repeat(101) });
    expect(sentIntents()).toEqual(['queue']);
    expect(mocks.getMailboxMessage).not.toHaveBeenCalled();
    expect(result).toMatchObject({
      deliveryIntent: 'auto',
      deliveredAs: 'queue',
      fallbackReason: 'too_long',
    });
  });

  it('measures the steer limit on trimmed content, like sendChat', async () => {
    mocks.getMailboxMessage.mockResolvedValue(STEERED);
    await send({ content: `  ${'x'.repeat(100)}  ` });
    expect(sentIntents()).toEqual(['steer']);
  });

  it('explicit steer falls back to the queue instead of throwing', async () => {
    const tooLong = await send({ deliveryIntent: 'steer', content: 'x'.repeat(101) });
    expect(tooLong).toMatchObject({
      deliveryIntent: 'steer',
      deliveredAs: 'queue',
      fallbackReason: 'too_long',
    });
    mocks.getMailboxMessage.mockResolvedValue(fellBack('session_not_awake'));
    const asleep = await send({ deliveryIntent: 'steer' });
    expect(asleep).toMatchObject({ deliveredAs: 'queue', fallbackReason: 'not_running' });
    expect(sentIntents()).toEqual(['queue', 'steer']);
  });

  it('auto queues when durable delivery (and so steering) is off', async () => {
    env.DURABLE_PROMPT_DELIVERY_ENABLED = 'false';
    const result = await send({});
    expect(sentIntents()).toEqual(['queue']);
    expect(result).toMatchObject({ deliveredAs: 'queue', fallbackReason: 'steering_unavailable' });
  });

  it('queue stays a plain queue with no fallback', async () => {
    const result = await send({ deliveryIntent: 'queue' });
    expect(sentIntents()).toEqual(['queue']);
    expect(mocks.getMailboxMessage).not.toHaveBeenCalled();
    expect(result).toMatchObject({ deliveryIntent: 'queue', deliveredAs: 'queue' });
    expect(result).not.toHaveProperty('fallbackReason');
  });

  it('a retry with the same requestKey delivers once and keeps the first answer', async () => {
    mocks.getMailboxMessage.mockResolvedValue(STEERED);
    const first = await send({}, ctx('fix-direction-1'));
    // By now the steer lane would have moved on; a replay must not re-decide.
    mocks.getMailboxMessage.mockResolvedValue(fellBack('no_running_turn'));
    const retry = await send({}, ctx('fix-direction-1'));
    expect(mocks.send).toHaveBeenCalledTimes(1);
    expect(retry).toEqual(first);
    expect(retry).toMatchObject({ deliveredAs: 'steer' });
    // The same key with a different intent is a different request, refused before delivery.
    await expect(send({ deliveryIntent: 'queue' }, ctx('fix-direction-1'))).rejects.toMatchObject({
      code: 'conflict',
    });
    expect(mocks.send).toHaveBeenCalledTimes(1);
  });

  it('rejects an unknown delivery intent', async () => {
    const parsed = samChatSend.input['~standard'].validate({
      projectId: 'project',
      sessionId: 'chat',
      content: 'x',
      deliveryIntent: 'interrupt',
    });
    expect('issues' in parsed && parsed.issues).toBeTruthy();
  });

  describe('sam_chat_delivery_get', () => {
    const get = () =>
      samChatDeliveryGet.run(ctx(), {
        projectId: 'project',
        sessionId: 'chat',
        deliveryId: 'delivery-1',
      });

    it('reports a steer the VM accepted into the running turn', async () => {
      mocks.getMailboxMessage.mockResolvedValue(STEERED);
      const result = await get();
      expect(result.steer).toEqual({ requested: true, state: 'steered' });
      expect(JSON.stringify(result)).not.toContain('secret prompt text');
    });

    it('reports a steer that fell back to the queue, with the reason', async () => {
      mocks.getMailboxMessage.mockResolvedValue(fellBack('no_running_turn'));
      expect((await get()).steer).toEqual({
        requested: true,
        state: 'fell_back_to_queue',
        fallbackReason: 'not_running',
        fallbackDetail: 'no_running_turn',
      });
    });

    it.each([
      ['delivering', 'pending'],
      ['queued', 'pending'],
      ['ambiguous', 'unconfirmed'],
      ['failed', 'failed'],
    ] as const)('maps an undecided steer in state %s to %s', async (deliveryState, state) => {
      mocks.getMailboxMessage.mockResolvedValue(row({ deliveryState, steerOutcome: null }));
      expect((await get()).steer).toEqual({ requested: true, state });
    });

    it('has no steer block for a plain queued message', async () => {
      mocks.getMailboxMessage.mockResolvedValue(
        row({ deliveryIntent: 'queue', steerOutcome: null })
      );
      const result = await get();
      expect(result.steer).toBeNull();
      expect(result).toMatchObject({ deliveryId: 'delivery-1', state: 'acked' });
    });
  });
});
