/**
 * Native app push: Apple Push Notification service (iOS/macOS) and Firebase
 * Cloud Messaging (Android). The Web Push sibling is `web-push.ts`; delivery
 * state lives in the Notification DO (`notification-native-push.ts`).
 *
 * Configuration is Worker secrets only, so every deployment brings its own app:
 * - APNs: APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (the .p8 key, as PEM or its
 *   base64), APNS_TOPIC (the app's bundle id).
 * - FCM: FCM_SERVICE_ACCOUNT_JSON (a service account key JSON, raw or base64).
 * A platform whose secrets are missing is skipped.
 */
import { importPKCS8, SignJWT } from 'jose';

export type NativePushPlatform = 'apns' | 'fcm';
export const NATIVE_PUSH_PLATFORMS = ['apns', 'fcm'] as const;

export interface NativePushEnv {
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_PRIVATE_KEY?: string;
  APNS_TOPIC?: string;
  FCM_SERVICE_ACCOUNT_JSON?: string;
}

export interface NativePushTarget {
  platform: NativePushPlatform;
  token: string;
  /** APNs development environment (debug builds). Ignored for FCM. */
  sandbox: boolean;
}

export interface NativePushMessage {
  title: string;
  body: string;
  /** Opaque routing data for the app (project, session, web path). */
  data: Record<string, string>;
}

export type NativePushResult =
  | { kind: 'success' }
  | { kind: 'gone'; status: number }
  | { kind: 'failure'; status: number | null };

interface SendOptions {
  ttlSeconds: number;
  timeoutMs: number;
  fetcher?: typeof fetch;
  now?: () => number;
}

// Protocol constants, not tunables: Apple rejects provider tokens older than an
// hour and refreshes more often than every 20 minutes (TooManyProviderTokenUpdates).
const APNS_TOKEN_REFRESH_MS = 40 * 60 * 1000;
const APNS_HOSTS = { production: 'api.push.apple.com', sandbox: 'api.sandbox.push.apple.com' };
const GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const GOOGLE_TOKEN_LIFETIME_S = 3600;
/** Renew a Google access token this long before it expires. */
const GOOGLE_TOKEN_MARGIN_MS = 5 * 60 * 1000;
const APNS_GONE_REASONS = new Set(['BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered']);

/** A secret stored as-is or base64 encoded (the GH_APP_PRIVATE_KEY practice). */
export function decodeSecretValue(value: string): string {
  const trimmed = value.trim().replace(/\\n/g, '\n');
  if (trimmed.startsWith('-----BEGIN') || trimmed.startsWith('{')) return trimmed;
  try {
    return atob(trimmed).trim();
  } catch {
    return trimmed;
  }
}

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

function parseServiceAccount(raw: string): ServiceAccount {
  const parsed: unknown = JSON.parse(decodeSecretValue(raw));
  if (
    typeof parsed !== 'object' ||
    parsed === null ||
    typeof (parsed as Record<string, unknown>).project_id !== 'string' ||
    typeof (parsed as Record<string, unknown>).client_email !== 'string' ||
    typeof (parsed as Record<string, unknown>).private_key !== 'string'
  ) {
    throw new Error('FCM_SERVICE_ACCOUNT_JSON is not a service account key');
  }
  return parsed as ServiceAccount;
}

interface ApnsConfig {
  keyId: string;
  teamId: string;
  privateKey: string;
  topic: string;
}

function apnsConfig(env: NativePushEnv): ApnsConfig | null {
  const keyId = env.APNS_KEY_ID?.trim();
  const teamId = env.APNS_TEAM_ID?.trim();
  const privateKey = env.APNS_PRIVATE_KEY?.trim();
  const topic = env.APNS_TOPIC?.trim();
  return keyId && teamId && privateKey && topic ? { keyId, teamId, privateKey, topic } : null;
}

export function isNativePushConfigured(platform: NativePushPlatform, env: NativePushEnv): boolean {
  return platform === 'apns'
    ? apnsConfig(env) !== null
    : Boolean(env.FCM_SERVICE_ACCOUNT_JSON?.trim());
}

// Per-isolate credential caches (.claude/rules/60): both providers rate-limit token minting.
let apnsToken: { cacheKey: string; token: string; issuedAt: number } | null = null;
let googleToken: { cacheKey: string; token: string; expiresAt: number } | null = null;

async function apnsAuthorization(
  { keyId, teamId, privateKey }: ApnsConfig,
  now: number
): Promise<string> {
  const cacheKey = `${teamId}:${keyId}`;
  if (apnsToken?.cacheKey === cacheKey && now - apnsToken.issuedAt < APNS_TOKEN_REFRESH_MS) {
    return apnsToken.token;
  }
  const key = await importPKCS8(decodeSecretValue(privateKey), 'ES256');
  const token = await new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt(Math.floor(now / 1000))
    .sign(key);
  apnsToken = { cacheKey, token, issuedAt: now };
  return token;
}

async function googleAccessToken(
  account: ServiceAccount,
  fetcher: typeof fetch,
  now: number,
  signal: AbortSignal
): Promise<string> {
  const cacheKey = account.client_email;
  if (googleToken?.cacheKey === cacheKey && now < googleToken.expiresAt - GOOGLE_TOKEN_MARGIN_MS) {
    return googleToken.token;
  }
  const key = await importPKCS8(account.private_key, 'RS256');
  const issuedAt = Math.floor(now / 1000);
  const assertion = await new SignJWT({ scope: FCM_SCOPE })
    .setProtectedHeader({ alg: 'RS256' })
    .setIssuer(account.client_email)
    .setAudience(GOOGLE_TOKEN_URL)
    .setIssuedAt(issuedAt)
    .setExpirationTime(issuedAt + GOOGLE_TOKEN_LIFETIME_S)
    .sign(key);
  const response = await fetcher(GOOGLE_TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
    signal,
  });
  if (!response.ok) throw new Error(`Google token exchange failed: HTTP ${response.status}`);
  const body: unknown = await response.json();
  const accessToken = (body as { access_token?: unknown }).access_token;
  const expiresIn =
    Number((body as { expires_in?: unknown }).expires_in) || GOOGLE_TOKEN_LIFETIME_S;
  if (typeof accessToken !== 'string') throw new Error('Google token response without a token');
  googleToken = { cacheKey, token: accessToken, expiresAt: now + expiresIn * 1000 };
  return accessToken;
}

async function sendApns(
  target: NativePushTarget,
  message: NativePushMessage,
  env: NativePushEnv,
  options: Required<SendOptions>,
  signal: AbortSignal
): Promise<NativePushResult> {
  const config = apnsConfig(env);
  if (!config) throw new Error('APNs is not configured');
  const now = options.now();
  const host = target.sandbox ? APNS_HOSTS.sandbox : APNS_HOSTS.production;
  const response = await options.fetcher(`https://${host}/3/device/${target.token}`, {
    method: 'POST',
    signal,
    headers: {
      authorization: `bearer ${await apnsAuthorization(config, now)}`,
      'apns-topic': config.topic,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      'apns-expiration': String(Math.floor(now / 1000) + options.ttlSeconds),
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      aps: {
        alert: { title: message.title, body: message.body },
        sound: 'default',
        ...(message.data.sessionId ? { 'thread-id': message.data.sessionId } : {}),
      },
      ...message.data,
    }),
  });
  if (response.ok) return { kind: 'success' };
  if (response.status === 410) return { kind: 'gone', status: 410 };
  if (response.status === 400) {
    const reason = ((await response.json().catch(() => ({}))) as { reason?: string }).reason;
    if (reason && APNS_GONE_REASONS.has(reason)) return { kind: 'gone', status: 400 };
  }
  return { kind: 'failure', status: response.status };
}

async function sendFcm(
  target: NativePushTarget,
  message: NativePushMessage,
  env: NativePushEnv,
  options: Required<SendOptions>,
  signal: AbortSignal
): Promise<NativePushResult> {
  const account = parseServiceAccount(env.FCM_SERVICE_ACCOUNT_JSON ?? '');
  const accessToken = await googleAccessToken(account, options.fetcher, options.now(), signal);
  const response = await options.fetcher(
    `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(account.project_id)}/messages:send`,
    {
      method: 'POST',
      signal,
      headers: { authorization: `Bearer ${accessToken}`, 'content-type': 'application/json' },
      // Data only: the app builds the notification itself, so a tap opens the
      // session whether the app was in the foreground or not.
      body: JSON.stringify({
        message: {
          token: target.token,
          data: { title: message.title, body: message.body, ...message.data },
          android: { priority: 'HIGH', ttl: `${options.ttlSeconds}s` },
        },
      }),
    }
  );
  if (response.ok) return { kind: 'success' };
  // 404 UNREGISTERED: the app was uninstalled or the token rotated.
  if (response.status === 404) return { kind: 'gone', status: 404 };
  return { kind: 'failure', status: response.status };
}

/** Send one message to one device. Never throws: errors become `failure`. */
export async function sendNativePush(
  target: NativePushTarget,
  message: NativePushMessage,
  env: NativePushEnv,
  options: SendOptions
): Promise<NativePushResult> {
  const resolved: Required<SendOptions> = {
    fetcher: options.fetcher ?? fetch,
    now: options.now ?? Date.now,
    ...options,
  } as Required<SendOptions>;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), resolved.timeoutMs);
  try {
    return target.platform === 'apns'
      ? await sendApns(target, message, env, resolved, controller.signal)
      : await sendFcm(target, message, env, resolved, controller.signal);
  } catch {
    return { kind: 'failure', status: null };
  } finally {
    clearTimeout(timeout);
  }
}
