/**
 * Native app push in the Notification DO: device token registration and the
 * fan-out to APNs/FCM. It mirrors `notification-push.ts` (Web Push): the same
 * payload builder, preference channel, tunables, receipts and pruning.
 */
import type { NotificationResponse } from '@simple-agent-manager/shared';
import {
  DEFAULT_WEB_PUSH_DELIVERY_TIMEOUT_MS,
  DEFAULT_WEB_PUSH_FAILURE_THRESHOLD,
  DEFAULT_WEB_PUSH_FANOUT_CONCURRENCY,
  DEFAULT_WEB_PUSH_MAX_SUBSCRIPTIONS_PER_USER,
  DEFAULT_WEB_PUSH_TTL_SECONDS,
  DEFAULT_WEB_PUSH_USER_AGENT_MAX_LENGTH,
} from '@simple-agent-manager/shared';

import { createModuleLogger } from '../lib/logger';
import type { NativePushEnv, NativePushMessage, NativePushTarget } from '../lib/native-push';
import { isNativePushConfigured, sendNativePush } from '../lib/native-push';
import type { WebPushEnv } from './notification-push';
import { buildDeclarativeWebPushPayload } from './notification-push';
import { parseNativePushTokenRows } from './notification-row-schemas';

const log = createModuleLogger('notification.native_push');

export type NativePushDeliveryEnv = NativePushEnv &
  WebPushEnv & {
    WEB_PUSH_MAX_SUBSCRIPTIONS_PER_USER?: string;
    WEB_PUSH_USER_AGENT_MAX_LENGTH?: string;
  };

function positiveInteger(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

/** Add or refresh a device token; a token moves to whoever registers it last. */
export function addNativePushToken(
  sql: SqlStorage,
  userId: string,
  target: NativePushTarget,
  userAgent: string | null,
  env: NativePushDeliveryEnv
): void {
  const now = Date.now();
  const maxUserAgent = positiveInteger(
    env.WEB_PUSH_USER_AGENT_MAX_LENGTH,
    DEFAULT_WEB_PUSH_USER_AGENT_MAX_LENGTH
  );
  sql.exec(
    `INSERT INTO native_push_tokens
       (token, user_id, platform, sandbox, user_agent, disabled_at, failure_count,
        last_success_at, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, NULL, 0, NULL, ?, ?)
     ON CONFLICT (token) DO UPDATE SET
       user_id = excluded.user_id,
       platform = excluded.platform,
       sandbox = excluded.sandbox,
       user_agent = excluded.user_agent,
       disabled_at = NULL,
       failure_count = 0,
       updated_at = excluded.updated_at`,
    target.token,
    userId,
    target.platform,
    target.sandbox ? 1 : 0,
    userAgent?.slice(0, maxUserAgent) ?? null,
    now,
    now
  );
  // Same per-user cap as browser subscriptions; the oldest device drops first.
  sql.exec(
    `DELETE FROM native_push_tokens
     WHERE token IN (
       SELECT token FROM native_push_tokens WHERE user_id = ?
       ORDER BY updated_at DESC, token DESC
       LIMIT -1 OFFSET ?
     )`,
    userId,
    positiveInteger(
      env.WEB_PUSH_MAX_SUBSCRIPTIONS_PER_USER,
      DEFAULT_WEB_PUSH_MAX_SUBSCRIPTIONS_PER_USER
    )
  );
}

export function removeNativePushToken(sql: SqlStorage, userId: string, token: string): boolean {
  return (
    sql.exec('DELETE FROM native_push_tokens WHERE token = ? AND user_id = ?', token, userId)
      .rowsWritten > 0
  );
}

/** Title, body and routing data, from the same builder Web Push uses. */
export function buildNativePushMessage(
  notification: NotificationResponse,
  appOrigin: string
): NativePushMessage {
  const web = buildDeclarativeWebPushPayload(notification, appOrigin).notification;
  const data: Record<string, string> = { url: web.navigate, notificationId: notification.id };
  if (notification.projectId) data.projectId = notification.projectId;
  if (notification.sessionId) data.sessionId = notification.sessionId;
  return { title: web.title, body: web.body, data };
}

/** Fan one notification out to the user's devices and record receipts/pruning. */
export async function deliverNotificationNativePush(
  sql: SqlStorage,
  userId: string,
  notification: NotificationResponse,
  appOrigin: string,
  env: NativePushDeliveryEnv
): Promise<void> {
  const rows = sql
    .exec('SELECT * FROM native_push_tokens WHERE user_id = ? AND disabled_at IS NULL', userId)
    .toArray();
  const tokens = parseNativePushTokenRows(rows, (index, error) => {
    log.warn('native_push.token_row_invalid', {
      index,
      error: error instanceof Error ? error.message : String(error),
    });
  }).filter((token) => {
    // An unconfigured platform is a deployment choice, not a device failure.
    if (isNativePushConfigured(token.platform, env)) return true;
    log.warn('native_push.platform_not_configured', { platform: token.platform });
    return false;
  });
  if (tokens.length === 0) return;

  const message = buildNativePushMessage(notification, appOrigin);
  const options = {
    ttlSeconds: positiveInteger(env.WEB_PUSH_TTL_SECONDS, DEFAULT_WEB_PUSH_TTL_SECONDS),
    timeoutMs: positiveInteger(
      env.WEB_PUSH_DELIVERY_TIMEOUT_MS,
      DEFAULT_WEB_PUSH_DELIVERY_TIMEOUT_MS
    ),
  };
  const failureThreshold = positiveInteger(
    env.WEB_PUSH_FAILURE_THRESHOLD,
    DEFAULT_WEB_PUSH_FAILURE_THRESHOLD
  );
  const concurrency = positiveInteger(
    env.WEB_PUSH_FANOUT_CONCURRENCY,
    DEFAULT_WEB_PUSH_FANOUT_CONCURRENCY
  );

  // ponytail: one attempt per device per notification; failures count toward the
  // same disable threshold as Web Push. Add retries if providers 5xx often.
  for (let offset = 0; offset < tokens.length; offset += concurrency) {
    await Promise.all(
      tokens.slice(offset, offset + concurrency).map(async (token) => {
        const result = await sendNativePush(token, message, env, options);
        const now = Date.now();
        if (result.kind === 'success') {
          sql.exec(
            `UPDATE native_push_tokens
             SET failure_count = 0, last_success_at = ?, updated_at = ?
             WHERE token = ? AND user_id = ?`,
            now,
            now,
            token.token,
            userId
          );
          sql.exec(
            'UPDATE notifications SET push_delivered_at = ? WHERE id = ? AND user_id = ?',
            now,
            notification.id,
            userId
          );
        } else if (result.kind === 'gone') {
          removeNativePushToken(sql, userId, token.token);
        } else {
          log.warn('native_push.delivery_failed', {
            platform: token.platform,
            status: result.status,
            notificationId: notification.id,
          });
          sql.exec(
            `UPDATE native_push_tokens
             SET failure_count = failure_count + 1,
                 disabled_at = CASE WHEN failure_count + 1 >= ? THEN ? ELSE disabled_at END,
                 updated_at = ?
             WHERE token = ? AND user_id = ?`,
            failureThreshold,
            now,
            now,
            token.token,
            userId
          );
        }
      })
    );
  }
}
