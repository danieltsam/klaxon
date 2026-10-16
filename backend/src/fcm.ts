import admin from 'firebase-admin';
import fs from 'fs';
import path from 'path';
import { DeviceRepo } from './db.js';

let isFirebaseInitialized = false;

export function initFirebase() {
  if (admin.apps.length > 0) {
    isFirebaseInitialized = true;
    return;
  }

  const candidates = [
    process.env.GOOGLE_APPLICATION_CREDENTIALS,
    path.resolve(process.cwd(), 'data', 'service-account.json'),
    path.resolve(process.cwd(), 'service-account.json'),
    '/app/data/service-account.json',
    '/app/service-account.json'
  ].filter(Boolean) as string[];

  let validPath: string | null = null;
  for (const p of candidates) {
    try {
      if (fs.existsSync(p) && fs.statSync(p).isFile()) {
        validPath = p;
        break;
      }
    } catch (_) {}
  }

  if (validPath) {
    try {
      const serviceAccount = JSON.parse(fs.readFileSync(validPath, 'utf8'));
      admin.initializeApp({
        credential: admin.credential.cert(serviceAccount)
      });
      isFirebaseInitialized = true;
      console.log(`[FCM] Firebase Admin successfully initialized using: ${validPath}`);
    } catch (err) {
      console.error('[FCM] Failed to initialize Firebase Admin with service account file:', err);
    }
  } else {
    try {
      // Attempt default application credentials
      admin.initializeApp({
        projectId: process.env.FIREBASE_PROJECT_ID || 'remote-alarm-sys-84926'
      });
      isFirebaseInitialized = true;
      console.log('[FCM] Firebase Admin initialized using default application credentials');
    } catch (err) {
      console.warn(`[FCM] No valid Firebase credentials found in [${candidates.join(', ')}]. Running in DRY-RUN / MOCK mode.`);
    }
  }
}

export interface FcmPayload {
  id: string;
  target_time?: string;
  label?: string;
  repeat_days?: string;
  sound_tone?: string;
  ramp_seconds?: number | string;
  description?: string;
  recurrence_interval_weeks?: number | string;
  recurrence_anchor_date?: string;
  [key: string]: any;
}

export type FcmAction = 'CREATE' | 'CANCEL' | 'DISMISS' | 'DISABLE';

/** Freshness window for an FCM message: 1 hour. Safety still comes from local-first arming. */
export const FCM_TTL_MS = 60 * 60 * 1000;

/** FCM's hard limit for a data payload. A message over this is rejected by FCM. */
export const FCM_MAX_PAYLOAD_BYTES = 4096;

/**
 * Build the string-valued data map FCM transports. FCM data values must be strings.
 */
export function buildFcmData(action: FcmAction, payload: FcmPayload): Record<string, string> {
  const dataPayload: Record<string, string> = {
    action,
    id: payload.id
  };

  if (payload.target_time) {
    dataPayload.target_time = payload.target_time;
  }
  if (payload.label) {
    dataPayload.label = payload.label;
  }
  if (payload.repeat_days) {
    dataPayload.repeat_days = payload.repeat_days;
  }
  if (payload.sound_tone) {
    dataPayload.sound_tone = payload.sound_tone;
  }
  if (payload.ramp_seconds !== undefined) {
    dataPayload.ramp_seconds = String(payload.ramp_seconds);
  }
  if (payload.description) {
    dataPayload.description = payload.description;
  }
  dataPayload.recurrence_interval_weeks = String(payload.recurrence_interval_weeks ?? 1);
  dataPayload.recurrence_anchor_date = payload.recurrence_anchor_date ?? '';

  return dataPayload;
}

/**
 * Guard the payload before send so an oversized message fails loudly instead of
 * being silently dropped at FCM's 4096-byte wall.
 */
export function validateFcmPayload(payload: FcmPayload): { ok: true } | { ok: false; error: string } {
  const bytes = Buffer.byteLength(JSON.stringify(buildFcmData('CREATE', payload)), 'utf8');
  if (bytes > FCM_MAX_PAYLOAD_BYTES) {
    return { ok: false, error: `FCM payload exceeds 4096 bytes (got ${bytes})` };
  }
  return { ok: true };
}

/**
 * Build a complete per-token FCM message: high priority, a moderate TTL (freshness,
 * not safety), and a per-alarm collapse key so a superseded schedule is replaced.
 */
export function buildFcmMessage(
  action: FcmAction,
  payload: FcmPayload,
  token: string
): Record<string, unknown> {
  return {
    token,
    android: {
      priority: 'high',
      ttl: FCM_TTL_MS,
      collapseKey: `alarm:${payload.id}`
    },
    data: buildFcmData(action, payload)
  };
}

/**
 * A token is dead only when FCM says it is not registered. A payload error
 * (`messaging/invalid-argument`) must NOT prune a healthy token.
 */
export function shouldPruneToken(code: string | undefined): boolean {
  return code === 'messaging/registration-token-not-registered';
}

export interface RetryOptions {
  attempts?: number;
  baseDelayMs?: number;
  isRetryable?: (e: unknown) => boolean;
  sleep?: (ms: number) => Promise<void>;
}

/**
 * Retry a transient operation with exponential backoff. A non-retryable error
 * (by default, a dead-token prune code) is rethrown immediately.
 */
export async function withRetry<T>(fn: () => Promise<T>, opts: RetryOptions = {}): Promise<T> {
  const attempts = opts.attempts ?? 3;
  const baseDelayMs = opts.baseDelayMs ?? 500;
  const isRetryable = opts.isRetryable ?? ((e: unknown) => !shouldPruneToken((e as { code?: string } | undefined)?.code));
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));

  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (!isRetryable(err) || attempt === attempts - 1) {
        throw err;
      }
      await sleep(baseDelayMs * 2 ** attempt);
    }
  }

  // Unreachable: the loop either returns or throws.
  throw new Error('withRetry: no attempts were made');
}

export async function sendFcmDataMessage(
  action: FcmAction,
  payload: FcmPayload
): Promise<{ sent: number; failed: number }> {
  const tokens = DeviceRepo.getAllTokens();

  if (tokens.length === 0) {
    console.log(`[FCM] No registered devices to send ${action} message for alarm ${payload.id}`);
    return { sent: 0, failed: 0 };
  }

  const validation = validateFcmPayload(payload);
  if (!validation.ok) {
    console.error(`[FCM] Refusing to send ${action} for alarm ${payload.id}: ${validation.error}`);
    return { sent: 0, failed: tokens.length };
  }

  const dataPayload = buildFcmData(action, payload);

  console.log(`[FCM] Dispatching ${action} data payload to ${tokens.length} device(s):`, dataPayload);

  if (!isFirebaseInitialized) {
    console.warn('[FCM] (Mock Mode) Firebase Admin not configured. Message simulated for tokens:', tokens);
    return { sent: tokens.length, failed: 0 };
  }

  let sent = 0;
  let failed = 0;

  for (const token of tokens) {
    const message = buildFcmMessage(action, payload, token) as unknown as admin.messaging.Message;

    try {
      await withRetry(() => admin.messaging().send(message));
      sent++;
      console.log(`[FCM] Successfully delivered ${action} to token ${token.slice(0, 10)}...`);
    } catch (err: any) {
      failed++;
      console.error(`[FCM] Error sending message to token ${token.slice(0, 10)}...:`, err.message || err);
      // Prune only a genuinely dead token; a payload error must not delete a healthy one.
      if (shouldPruneToken(err?.code)) {
        console.log(`[FCM] Pruning dead token from DB: ${token.slice(0, 10)}...`);
        DeviceRepo.remove(token);
      }
    }
  }

  return { sent, failed };
}
