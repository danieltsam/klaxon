import fastify from 'fastify';
import cors from '@fastify/cors';
import fastifyStatic from '@fastify/static';
import path from 'path';
import { v4 as uuidv4 } from 'uuid';
import dotenv from 'dotenv';
import { AlarmRepo, DeviceRepo, SettingsRepo, AlarmRecord, AppSettings } from './db.js';
import { initFirebase, sendFcmDataMessage, FcmPayload } from './fcm.js';

dotenv.config();

const app = fastify({ logger: true });

// Register CORS for client access
await app.register(cors, {
  origin: true,
  methods: ['GET', 'POST', 'DELETE', 'OPTIONS']
});

// Serve static dashboard files
await app.register(fastifyStatic, {
  root: path.resolve(process.cwd(), 'public'),
  prefix: '/'
});

// Initialize Firebase
initFirebase();

// 1. GET /api/alarms: Return alarms filtered by view ('active' | 'history' | 'all')
app.get<{
  Querystring: { view?: 'active' | 'history' | 'all' }
}>('/api/alarms', async (request, reply) => {
  const view = request.query?.view || 'active';
  const alarms = AlarmRepo.getAll(view);
  return reply.send(alarms);
});

// 1b. GET /api/calendar.ics: Export active alarms as standard RFC 5545 iCalendar feed
app.get('/api/calendar.ics', async (_request, reply) => {
  const alarms = AlarmRepo.getAll('active');

  const pad = (n: number) => n.toString().padStart(2, '0');
  const formatIcalDate = (date: Date): string => {
    return (
      date.getUTCFullYear() +
      pad(date.getUTCMonth() + 1) +
      pad(date.getUTCDate()) +
      'T' +
      pad(date.getUTCHours()) +
      pad(date.getUTCMinutes()) +
      pad(date.getUTCSeconds()) +
      'Z'
    );
  };

  const dayMap: Record<string, string> = {
    '1': 'MO',
    '2': 'TU',
    '3': 'WE',
    '4': 'TH',
    '5': 'FR',
    '6': 'SA',
    '7': 'SU'
  };

  const nowStamp = formatIcalDate(new Date());

  let icsLines: string[] = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//RemoteAlarm//Remote Alarm System//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'X-WR-CALNAME:Remote Alarms',
    'X-WR-TIMEZONE:UTC'
  ];

  for (const alarm of alarms) {
    const startDate = new Date(alarm.target_time);
    if (isNaN(startDate.getTime())) continue;

    // Alarm duration shown in calendar as 15 minutes
    const endDate = new Date(startDate.getTime() + 15 * 60 * 1000);

    icsLines.push('BEGIN:VEVENT');
    icsLines.push(`UID:${alarm.id}@remotealarm`);
    icsLines.push(`DTSTAMP:${nowStamp}`);
    icsLines.push(`DTSTART:${formatIcalDate(startDate)}`);
    icsLines.push(`DTEND:${formatIcalDate(endDate)}`);
    icsLines.push(`SUMMARY:⏰ ${alarm.label}`);
    icsLines.push(`DESCRIPTION:Alarm ID: ${alarm.id}\\nStatus: ${alarm.status}\\nManaged by Remote Alarm System`);

    if (alarm.repeat_days) {
      const days = alarm.repeat_days
        .split(',')
        .map(d => dayMap[d.trim()])
        .filter(Boolean);
      if (days.length > 0) {
        icsLines.push(`RRULE:FREQ=WEEKLY;BYDAY=${days.join(',')}`);
      }
    }

    icsLines.push('END:VEVENT');
  }

  icsLines.push('END:VCALENDAR');

  const icsBody = icsLines.join('\r\n') + '\r\n';

  return reply
    .header('Content-Type', 'text/calendar; charset=utf-8')
    .header('Content-Disposition', 'inline; filename="alarms.ics"')
    .header('Cache-Control', 'no-cache, no-store, must-revalidate')
    .send(icsBody);
});

// 2. POST /api/alarms: Create new alarm and broadcast FCM CREATE
app.post<{
  Body: {
    target_time: string;
    label: string;
    description?: string;
    repeat_days?: string | number[];
    sound_tone?: string;
    ramp_seconds?: number;
  }
}>('/api/alarms', async (request, reply) => {
  const { target_time, label, description, repeat_days, sound_tone, ramp_seconds } = request.body || {};

  if (!target_time || !label) {
    return reply.status(400).send({
      error: 'Missing required fields: target_time and label are required.'
    });
  }

  // Validate target_time format
  const dateObj = new Date(target_time);
  if (isNaN(dateObj.getTime())) {
    return reply.status(400).send({
      error: 'Invalid target_time: must be a valid ISO 8601 UTC timestamp.'
    });
  }

  // Align seconds and milliseconds to :00.000 for standard clock alarms
  dateObj.setSeconds(0, 0);

  // Normalize repeat_days to string
  let repeatDaysStr: string | undefined;
  if (Array.isArray(repeat_days)) {
    repeatDaysStr = repeat_days.join(',');
  } else if (typeof repeat_days === 'string' && repeat_days.trim().length > 0) {
    repeatDaysStr = repeat_days.trim();
  }

  const id = uuidv4();
  const normalizedTone = sound_tone && ['alarm', 'chime', 'digital'].includes(sound_tone.trim().toLowerCase())
    ? sound_tone.trim().toLowerCase()
    : 'alarm';
  const normalizedRamp = typeof ramp_seconds === 'number' && ramp_seconds >= 0 ? ramp_seconds : 30;

  const newAlarm: AlarmRecord = {
    id,
    target_time: dateObj.toISOString(),
    label: label.trim(),
    description: description ? description.trim() : undefined,
    status: 'pending',
    repeat_days: repeatDaysStr,
    sound_tone: normalizedTone,
    ramp_seconds: normalizedRamp
  };

  AlarmRepo.create(newAlarm);

  // Send FCM Data Message
  const fcmPayload: FcmPayload = {
    id: newAlarm.id,
    target_time: newAlarm.target_time,
    label: newAlarm.label,
    sound_tone: normalizedTone,
    ramp_seconds: normalizedRamp
  };
  if (newAlarm.description) {
    fcmPayload.description = newAlarm.description;
  }
  if (repeatDaysStr) {
    fcmPayload.repeat_days = repeatDaysStr;
  }

  const dispatchResult = await sendFcmDataMessage('CREATE', fcmPayload);

  return reply.status(201).send({
    ...newAlarm,
    fcm_dispatch: dispatchResult
  });
});

// 3. DELETE /api/alarms/:id: Cancel alarm and broadcast FCM CANCEL
app.delete<{
  Params: { id: string }
}>('/api/alarms/:id', async (request, reply) => {
  const { id } = request.params;
  const existing = AlarmRepo.getById(id);

  if (!existing) {
    return reply.status(404).send({ error: 'Alarm not found' });
  }

  AlarmRepo.cancel(id);

  // Broadcast cancel event
  const dispatchResult = await sendFcmDataMessage('CANCEL', { id });

  return reply.send({
    success: true,
    id,
    status: 'canceled',
    fcm_dispatch: dispatchResult
  });
});

// 3b. POST /api/alarms/:id/silence: Remotely silence a ringing alarm and broadcast FCM DISMISS
app.post<{
  Params: { id: string }
}>('/api/alarms/:id/silence', async (request, reply) => {
  const { id } = request.params;
  const existing = AlarmRepo.getById(id);

  if (!existing) {
    return reply.status(404).send({ error: 'Alarm not found' });
  }

  AlarmRepo.updateStatus(id, 'dismissed');

  // Broadcast remote silence/dismiss event to phone
  const dispatchResult = await sendFcmDataMessage('DISMISS', { id });

  return reply.send({
    success: true,
    id,
    status: 'dismissed',
    fcm_dispatch: dispatchResult
  });
});

// 4. POST /api/alarms/:id/state: Update status ('ringing' | 'dismissed' | 'snoozed' | 'pending' | 'disabled')
app.post<{
  Params: { id: string };
  Body: { status: 'ringing' | 'dismissed' | 'snoozed' | 'pending' | 'disabled' }
}>('/api/alarms/:id/state', async (request, reply) => {
  const { id } = request.params;
  const { status } = request.body || {};

  const validStatuses = ['ringing', 'dismissed', 'snoozed', 'pending', 'disabled'];
  if (!status || !validStatuses.includes(status)) {
    return reply.status(400).send({
      error: `Invalid status. Must be one of: ${validStatuses.join(', ')}.`
    });
  }

  const existing = AlarmRepo.getById(id);
  if (!existing) {
    return reply.status(404).send({ error: 'Alarm not found' });
  }

  AlarmRepo.updateStatus(id, status);

  let fcmResult;
  if (status === 'disabled') {
    fcmResult = await sendFcmDataMessage('DISABLE', { id });
  } else if (status === 'pending') {
    const fcmPayload: FcmPayload = {
      id: existing.id,
      target_time: existing.target_time,
      label: existing.label,
      sound_tone: existing.sound_tone || 'alarm',
      ramp_seconds: existing.ramp_seconds ?? 30
    };
    if (existing.repeat_days) {
      fcmPayload.repeat_days = existing.repeat_days;
    }
    fcmResult = await sendFcmDataMessage('CREATE', fcmPayload);
  }

  return reply.send({
    success: true,
    id,
    status,
    fcm_dispatch: fcmResult
  });
});

// 5. POST /api/devices/register: Upsert device token with battery and status metadata
app.post<{
  Body: {
    token: string;
    battery_level?: number | null;
    is_charging?: boolean | number | null;
    device_name?: string | null;
  }
}>('/api/devices/register', async (request, reply) => {
  const { token, battery_level, is_charging, device_name } = request.body || {};

  if (!token || typeof token !== 'string') {
    return reply.status(400).send({
      error: 'Missing or invalid device token'
    });
  }

  DeviceRepo.upsert(token.trim(), {
    battery_level,
    is_charging,
    device_name
  });

  return reply.send({
    success: true,
    message: 'Device registered successfully'
  });
});

// 6. GET /api/devices: List count, devices with battery telemetry, and masked tokens
app.get('/api/devices', async (_request, reply) => {
  const devices = DeviceRepo.getAllDevices();
  return reply.send({
    count: devices.length,
    tokens: devices.map(d => `${d.token.slice(0, 10)}...${d.token.slice(-6)}`),
    devices: devices.map(d => ({
      token_masked: `${d.token.slice(0, 10)}...${d.token.slice(-6)}`,
      device_name: d.device_name || 'Android Phone',
      battery_level: d.battery_level,
      is_charging: d.is_charging === 1 || d.is_charging === true,
      updated_at: d.updated_at
    }))
  });
});

// 7. GET /api/settings: Return persisted application settings
app.get('/api/settings', async (_request, reply) => {
  const settings = SettingsRepo.getAll();
  return reply.send(settings);
});

// 8. POST /api/settings: Update application settings
app.post<{
  Body: Partial<AppSettings>;
}>('/api/settings', async (request, reply) => {
  const { sound_tone, ramp_seconds, date_format, time_format } = request.body || {};

  const updates: Partial<AppSettings> = {};

  if (sound_tone !== undefined) {
    const validTones = ['alarm', 'chime', 'digital'];
    if (!validTones.includes(sound_tone)) {
      return reply.status(400).send({
        error: `Invalid sound_tone. Must be one of: ${validTones.join(', ')}.`
      });
    }
    updates.sound_tone = sound_tone;
  }

  if (ramp_seconds !== undefined) {
    const validRamps = [0, 15, 30, 60];
    if (typeof ramp_seconds !== 'number' || !validRamps.includes(ramp_seconds)) {
      return reply.status(400).send({
        error: `Invalid ramp_seconds. Must be one of: ${validRamps.join(', ')}.`
      });
    }
    updates.ramp_seconds = ramp_seconds;
  }

  if (date_format !== undefined) {
    const validDates = ['dd/mm/yyyy', 'mm/dd/yyyy', 'yyyy-mm-dd'];
    if (!validDates.includes(date_format)) {
      return reply.status(400).send({
        error: `Invalid date_format. Must be one of: ${validDates.join(', ')}.`
      });
    }
    updates.date_format = date_format;
  }

  if (time_format !== undefined) {
    const validTimes = ['24h', '12h'];
    if (!validTimes.includes(time_format)) {
      return reply.status(400).send({
        error: `Invalid time_format. Must be one of: ${validTimes.join(', ')}.`
      });
    }
    updates.time_format = time_format;
  }

  const updated = SettingsRepo.update(updates);
  return reply.send({
    success: true,
    settings: updated
  });
});

export { app };

if (process.env.NODE_ENV !== 'test') {
  const PORT = parseInt(process.env.PORT || '3000', 10);
  const HOST = process.env.HOST || '0.0.0.0';

  try {
    await app.listen({ port: PORT, host: HOST });
    console.log(`\n[Server] Remote Alarm Backend running at http://${HOST}:${PORT}`);
    console.log(`[Server] Dashboard available at http://localhost:${PORT}\n`);
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
}
