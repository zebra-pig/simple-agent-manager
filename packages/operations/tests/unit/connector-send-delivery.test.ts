import type { AgentMailboxMessage } from '@simple-agent-manager/shared';
import { describe, expect, it, vi } from 'vitest';

import {
  awaitSteerDecision,
  deliveryOutcome,
  normalizeSteerFallbackReason,
  planConnectorDelivery,
  steerProjection,
} from '../../src/connector-send-delivery';

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

describe('connector send delivery helpers', () => {
  it('plans the inbox intent from the request', () => {
    const policy = { available: true, maxContentLength: 10 };
    expect(planConnectorDelivery('auto', 10, policy)).toEqual({ sendAs: 'steer', fallback: null });
    expect(planConnectorDelivery('steer', 11, policy)).toEqual({
      sendAs: 'queue',
      fallback: 'too_long',
    });
    expect(planConnectorDelivery('queue', 1, policy)).toEqual({ sendAs: 'queue', fallback: null });
  });

  it('normalizes unknown runtime reasons without dropping them', () => {
    expect(normalizeSteerFallbackReason('turn_cancelling')).toBe('not_running');
    expect(normalizeSteerFallbackReason(null)).toBe('steering_unavailable');
  });

  it('answers pending when the steer stays undecided past the bound', async () => {
    let clock = 0;
    const read = vi
      .fn()
      .mockResolvedValue(row({ deliveryState: 'delivering', steerOutcome: null }));
    const decided = await awaitSteerDecision(read, {
      waitMs: 1_000,
      pollMs: 400,
      now: () => clock,
      sleep: async (ms) => {
        clock += ms;
      },
    });
    expect(read).toHaveBeenCalledTimes(3);
    expect(deliveryOutcome(decided)).toEqual({ deliveredAs: 'pending' });
  });

  it('stops polling as soon as the steer is decided and survives a failed read', async () => {
    const read = vi
      .fn()
      .mockRejectedValueOnce(new Error('DO unavailable'))
      .mockResolvedValueOnce(row());
    const decided = await awaitSteerDecision(read, { sleep: async () => {} });
    expect(read).toHaveBeenCalledTimes(2);
    expect(deliveryOutcome(decided)).toEqual({ deliveredAs: 'steer' });
  });

  it('reports an ambiguous steer as unconfirmed, never as steered', () => {
    expect(deliveryOutcome(row({ deliveryState: 'ambiguous', steerOutcome: null }))).toEqual({
      deliveredAs: 'unconfirmed',
    });
  });

  it('projects no steer block for a message never sent as a steer', () => {
    expect(steerProjection(row({ deliveryIntent: 'queue', steerOutcome: null }))).toBeNull();
  });
});
