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

export async function sendFcmDataMessage(
  action: 'CREATE' | 'CANCEL' | 'DISMISS' | 'DISABLE',
  payload: FcmPayload
): Promise<{ sent: number; failed: number }> {
  const tokens = DeviceRepo.getAllTokens();

  if (tokens.length === 0) {
    console.log(`[FCM] No registered devices to send ${action} message for alarm ${payload.id}`);
    return { sent: 0, failed: 0 };
  }

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

  console.log(`[FCM] Dispatching ${action} data payload to ${tokens.length} device(s):`, dataPayload);

  if (!isFirebaseInitialized) {
    console.warn('[FCM] (Mock Mode) Firebase Admin not configured. Message simulated for tokens:', tokens);
    return { sent: tokens.length, failed: 0 };
  }

  let sent = 0;
  let failed = 0;

  for (const token of tokens) {
    const message: admin.messaging.Message = {
      token,
      android: {
        priority: 'high'
      },
      data: dataPayload
    };

    try {
      await admin.messaging().send(message);
      sent++;
      console.log(`[FCM] Successfully delivered ${action} to token ${token.slice(0, 10)}...`);
    } catch (err: any) {
      failed++;
      console.error(`[FCM] Error sending message to token ${token.slice(0, 10)}...:`, err.message || err);
      // Prune invalid or unregistered tokens
      if (
        err.code === 'messaging/registration-token-not-registered' ||
        err.code === 'messaging/invalid-argument'
      ) {
        console.log(`[FCM] Pruning invalid token from DB: ${token.slice(0, 10)}...`);
        DeviceRepo.remove(token);
      }
    }
  }

  return { sent, failed };
}
