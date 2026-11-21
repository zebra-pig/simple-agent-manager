/**
 * How a Connector reply reaches an agent: into its running turn (steer) or as its next
 * prompt (queue).
 *
 * `sam_chat_send` asks the durable inbox for a `steer` whenever one can be carried at all.
 * The inbox's steer lane is the authority on the rest: it steers only a live runtime that
 * is running a turn and speaks the steering protocol, and otherwise hands the message,
 * visibly, to the ordinary queue lane, which wakes a sleeping session as before
 * (`vm-steer-delivery-adapter.ts`, `prompt-delivery-steer.ts`). This module turns the
 * resulting inbox row into what the caller sees: what was requested, what actually
 * happened, and why it fell back.
 */
import type { AgentMailboxMessage, PromptDeliveryIntent } from '@simple-agent-manager/shared';
import * as v from 'valibot';

/** `auto` (default): steer when possible, otherwise queue. Never fails where a queue would not. */
export const CONNECTOR_DELIVERY_INTENTS = ['auto', 'steer', 'queue'] as const;
export type ConnectorDeliveryIntent = (typeof CONNECTOR_DELIVERY_INTENTS)[number];
export const ConnectorDeliveryIntentSchema = v.picklist(CONNECTOR_DELIVERY_INTENTS);

/**
 * Why a message meant for the running turn went to the queue instead. Normalized from the
 * runtime's reasons; the raw reason is kept as `fallbackDetail`.
 */
export type SteerFallbackReason =
  'not_running' | 'runtime_steering_unsupported' | 'too_long' | 'steering_unavailable';

/** What a send became. `pending`/`unconfirmed`/`failed` are the honest answers when no
 * delivery decision is known (yet), so a caller never reads a guess as a fact. */
export type DeliveredAs = 'steer' | 'queue' | 'pending' | 'unconfirmed' | 'failed';

const NOT_RUNNING_REASONS = new Set([
  'session_not_awake',
  'no_running_turn',
  'agent_session_unavailable',
  'runtime_not_ready',
  'turn_stopping',
  'turn_cancelling',
]);
const UNSUPPORTED_REASONS = new Set([
  'runtime_steering_unsupported',
  'adapter_does_not_advertise_steering',
  'adapter_idle_behavior_unverified',
  'unsupported',
]);

export function normalizeSteerFallbackReason(reason: string | null): SteerFallbackReason {
  if (reason && NOT_RUNNING_REASONS.has(reason)) return 'not_running';
  if (reason && UNSUPPORTED_REASONS.has(reason)) return 'runtime_steering_unsupported';
  if (reason === 'too_long') return 'too_long';
  return 'steering_unavailable';
}

/** The inbox intent a Connector request is sent with, decided before any side effect. */
export function planConnectorDelivery(
  requested: ConnectorDeliveryIntent,
  contentLength: number,
  policy: { available: boolean; maxContentLength: number }
): { sendAs: PromptDeliveryIntent; fallback: SteerFallbackReason | null } {
  if (requested === 'queue') return { sendAs: 'queue', fallback: null };
  if (!policy.available) return { sendAs: 'queue', fallback: 'steering_unavailable' };
  if (contentLength > policy.maxContentLength) return { sendAs: 'queue', fallback: 'too_long' };
  return { sendAs: 'steer', fallback: null };
}

/** The steer state a delivery row records; `null` when no steer was ever attempted. */
export type SteerState = 'steered' | 'fell_back_to_queue' | 'pending' | 'unconfirmed' | 'failed';

type SteerFields = Pick<
  AgentMailboxMessage,
  'deliveryIntent' | 'deliveryState' | 'steerOutcome' | 'steerReason'
>;

export function steerState(m: SteerFields): SteerState | null {
  if (m.steerOutcome === 'steered') return 'steered';
  if (m.steerOutcome === 'queued_fallback') return 'fell_back_to_queue';
  if (m.deliveryIntent !== 'steer') return null;
  switch (m.deliveryState) {
    case 'ambiguous':
      return 'unconfirmed';
    case 'failed':
    case 'expired':
      return 'failed';
    default:
      return 'pending';
  }
}

/**
 * The steer block of `sam_chat_delivery_get`. `steered` means the VM's receipt reported the
 * text injected into the running turn (not proof the model acted on it); `fell_back_to_queue`
 * means the VM (or SAM) did not take it and the message is the agent's next prompt instead.
 */
export function steerProjection(m: SteerFields) {
  const state = steerState(m);
  if (state === null) return null;
  return {
    requested: true,
    state,
    ...(state === 'fell_back_to_queue'
      ? {
          fallbackReason: normalizeSteerFallbackReason(m.steerReason),
          fallbackDetail: m.steerReason,
        }
      : {}),
  };
}

/** What the send result says about a steer request once its inbox row is read. */
export function deliveryOutcome(m: SteerFields | null): {
  deliveredAs: DeliveredAs;
  fallbackReason?: SteerFallbackReason;
  fallbackDetail?: string | null;
} {
  const state = m ? steerState(m) : 'pending';
  switch (state) {
    case 'steered':
      return { deliveredAs: 'steer' };
    case 'fell_back_to_queue':
      return {
        deliveredAs: 'queue',
        fallbackReason: normalizeSteerFallbackReason(m?.steerReason ?? null),
        fallbackDetail: m?.steerReason ?? null,
      };
    case 'unconfirmed':
      return { deliveredAs: 'unconfirmed' };
    case 'failed':
      return { deliveredAs: 'failed' };
    case null:
      return { deliveredAs: 'queue' };
    default:
      return { deliveredAs: 'pending' };
  }
}

/** How long a send waits for the inbox to decide a steer before answering `pending`. */
export const STEER_DECISION_WAIT_MS = 6_000;
export const STEER_DECISION_POLL_MS = 400;

/**
 * Re-read the delivery until its steer is decided or the bound passes. Reads only; a lookup
 * failure is `null`, which the caller reports as `pending` (the delivery itself is unaffected).
 */
export async function awaitSteerDecision(
  read: () => Promise<SteerFields | null>,
  options: {
    waitMs?: number;
    pollMs?: number;
    sleep?: (ms: number) => Promise<void>;
    now?: () => number;
  } = {}
): Promise<SteerFields | null> {
  const waitMs = options.waitMs ?? STEER_DECISION_WAIT_MS;
  const pollMs = options.pollMs ?? STEER_DECISION_POLL_MS;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const now = options.now ?? Date.now;
  const deadline = now() + waitMs;
  let last: SteerFields | null = null;
  for (;;) {
    try {
      last = await read();
    } catch {
      last = null;
    }
    if (last && steerState(last) !== 'pending') return last;
    if (now() + pollMs > deadline) return last;
    await sleep(pollMs);
  }
}
