import { env, runInDurableObject } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { NotificationService } from '../../src/durable-objects/notification';
import { deliverNotificationNativePush } from '../../src/durable-objects/notification-native-push';
import type { NativePushEnv } from '../../src/lib/native-push';

function stub(userId: string): DurableObjectStub<NotificationService> {
  return env.NOTIFICATION.get(
    env.NOTIFICATION.idFromName(userId)
  ) as DurableObjectStub<NotificationService>;
}

async function pkcs8Pem(algorithm: RsaHashedKeyGenParams | EcKeyGenParams): Promise<string> {
  const pair = (await crypto.subtle.generateKey(algorithm, true, [
    'sign',
    'verify',
  ])) as CryptoKeyPair;
  const der = new Uint8Array(
    (await crypto.subtle.exportKey('pkcs8', pair.privateKey)) as ArrayBuffer
  );
  let binary = '';
  for (const byte of der) binary += String.fromCharCode(byte);
  return `-----BEGIN PRIVATE KEY-----\n${btoa(binary)}\n-----END PRIVATE KEY-----`;
}

/** Credentials minted per run, stored base64 encoded the way the deploy stores them. */
async function nativeEnv(): Promise<NativePushEnv> {
  const apnsKey = await pkcs8Pem({ name: 'ECDSA', namedCurve: 'P-256' });
  const fcmKey = await pkcs8Pem({
    name: 'RSASSA-PKCS1-v1_5',
    modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]),
    hash: 'SHA-256',
  });
  return {
    APNS_KEY_ID: 'KEY1234567',
    APNS_TEAM_ID: 'TEAM123456',
    APNS_PRIVATE_KEY: btoa(apnsKey),
    APNS_TOPIC: 'org.example.sam',
    FCM_SERVICE_ACCOUNT_JSON: btoa(
      JSON.stringify({
        project_id: 'sam-test',
        client_email: 'push@sam-test.iam',
        private_key: fcmKey,
      })
    ),
  };
}

async function deliver(userId: string, notificationId: string, pushEnv: NativePushEnv) {
  const notification = stub(userId);
  await runInDurableObject(notification, async (instance, state) => {
    const created = await instance.listNotifications(userId, {});
    const target = created.notifications.find((n) => n.id === notificationId)!;
    await deliverNotificationNativePush(
      state.storage.sql,
      userId,
      target,
      'https://app.example.com',
      pushEnv
    );
  });
}

/** Like workerd's fetch: refuses to run as a method of another object ("Illegal invocation"). */
function strictFetch(impl: (url: string, init?: RequestInit) => Promise<Response>) {
  return function (this: unknown, url: string, init?: RequestInit) {
    if (this !== undefined && this !== globalThis) throw new TypeError('Illegal invocation');
    return impl(url, init);
  };
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('Notification DO native push', () => {
  it('registers through the route and sends to APNs and FCM with a delivery receipt', async () => {
    const userId = `native-push-${crypto.randomUUID()}`;
    const notification = stub(userId);
    await notification.addNativePushToken(userId, {
      platform: 'apns',
      token: 'a1b2c3',
      sandbox: true,
    });
    await notification.addNativePushToken(userId, {
      platform: 'fcm',
      token: 'fcm:tok_1',
      sandbox: false,
    });
    const created = await notification.createNotification(userId, {
      type: 'needs_input',
      urgency: 'high',
      title: 'Approval needed',
      body: 'Choose a release window',
      projectId: 'project-1',
      sessionId: 'session-1',
      actionUrl: '/projects/project-1/chat/session-1',
    });

    const fetchMock = vi.fn(async (url: string) =>
      url === 'https://oauth2.googleapis.com/token'
        ? Response.json({ access_token: 'google-token', expires_in: 3600 })
        : new Response('{}', { status: 200 })
    );
    vi.stubGlobal('fetch', strictFetch(fetchMock));
    await deliver(userId, created.id, await nativeEnv());

    const byUrl = new Map(fetchMock.mock.calls.map(([url, init]) => [url, init as RequestInit]));
    const apns = byUrl.get('https://api.sandbox.push.apple.com/3/device/a1b2c3')!;
    expect(apns.headers).toMatchObject({
      authorization: expect.stringMatching(/^bearer ey/),
      'apns-topic': 'org.example.sam',
      'apns-push-type': 'alert',
    });
    expect(JSON.parse(apns.body as string)).toEqual({
      aps: {
        alert: { title: 'Approval needed', body: 'Choose a release window' },
        sound: 'default',
        'thread-id': 'session-1',
      },
      url: 'https://app.example.com/projects/project-1/chat/session-1',
      notificationId: created.id,
      projectId: 'project-1',
      sessionId: 'session-1',
    });
    const fcm = byUrl.get('https://fcm.googleapis.com/v1/projects/sam-test/messages:send')!;
    expect(fcm.headers).toMatchObject({ authorization: 'Bearer google-token' });
    expect(JSON.parse(fcm.body as string).message).toMatchObject({
      token: 'fcm:tok_1',
      data: { title: 'Approval needed', sessionId: 'session-1', projectId: 'project-1' },
    });
    expect(await notification.hasConfirmedPushDelivery(userId, created.id)).toBe(true);
  });

  it('prunes tokens the provider reports gone and keeps the rest', async () => {
    const userId = `native-push-gone-${crypto.randomUUID()}`;
    const notification = stub(userId);
    await notification.addNativePushToken(userId, {
      platform: 'apns',
      token: 'dead01',
      sandbox: false,
    });
    await notification.addNativePushToken(userId, {
      platform: 'apns',
      token: 'live01',
      sandbox: false,
    });
    const created = await notification.createNotification(userId, {
      type: 'needs_input',
      urgency: 'high',
      title: 'Hello',
    });
    const pushEnv = await nativeEnv();

    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) =>
        url.endsWith('/dead01')
          ? Response.json({ reason: 'Unregistered' }, { status: 410 })
          : new Response('{}', { status: 500 })
      )
    );
    await deliver(userId, created.id, pushEnv);

    const fetchMock = vi.fn(async () => new Response('{}', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    await deliver(userId, created.id, pushEnv);
    // The gone token is never tried again; the failing one still is.
    expect(fetchMock.mock.calls.map(([url]) => url)).toEqual([
      'https://api.push.apple.com/3/device/live01',
    ]);
  });

  it('skips a platform the deployment has not configured', async () => {
    const userId = `native-push-unconfigured-${crypto.randomUUID()}`;
    const notification = stub(userId);
    await notification.addNativePushToken(userId, {
      platform: 'fcm',
      token: 'fcm-only',
      sandbox: false,
    });
    const created = await notification.createNotification(userId, {
      type: 'needs_input',
      urgency: 'high',
      title: 'Hello',
    });
    const fetchMock = vi.fn(async () => new Response('{}', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    const apnsOnly = { ...(await nativeEnv()), FCM_SERVICE_ACCOUNT_JSON: undefined };
    await deliver(userId, created.id, apnsOnly);
    expect(fetchMock).not.toHaveBeenCalled();
    // Liveness: the token was kept, so configuring FCM later delivers to it.
    await deliver(userId, created.id, await nativeEnv());
    expect(fetchMock).toHaveBeenCalled();
  });
});
