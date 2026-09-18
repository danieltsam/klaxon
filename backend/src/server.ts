import fastify from 'fastify';
import cors from '@fastify/cors';
import fastifyStatic from '@fastify/static';
import path from 'path';
import { v4 as uuidv4 } from 'uuid';
import dotenv from 'dotenv';
import { AlarmRepo, DeviceRepo, AlarmRecord } from './db.js';
import { initFirebase, sendFcmDataMessage } from './fcm.js';

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
  Body: { target_time: string; label: string; repeat_days?: string | number[] }
}>('/api/alarms', async (request, reply) => {
  const { target_time, label, repeat_days } = request.body || {};

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
  const newAlarm: AlarmRecord = {
    id,
    target_time: dateObj.toISOString(),
    label: label.trim(),
    status: 'pending',
    repeat_days: repeatDaysStr
  };

  AlarmRepo.create(newAlarm);

  // Send FCM Data Message
  const fcmPayload: Record<string, string> = {
    id: newAlarm.id,
    target_time: newAlarm.target_time,
    label: newAlarm.label
  };
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

// 4. POST /api/alarms/:id/state: Update status ('ringing' | 'dismissed' | 'snoozed')
app.post<{
  Params: { id: string };
  Body: { status: 'ringing' | 'dismissed' | 'snoozed' }
}>('/api/alarms/:id/state', async (request, reply) => {
  const { id } = request.params;
  const { status } = request.body || {};

  if (!status || !['ringing', 'dismissed', 'snoozed'].includes(status)) {
    return reply.status(400).send({
      error: 'Invalid status. Must be "ringing", "dismissed", or "snoozed".'
    });
  }

  const existing = AlarmRepo.getById(id);
  if (!existing) {
    return reply.status(404).send({ error: 'Alarm not found' });
  }

  AlarmRepo.updateStatus(id, status);

  return reply.send({
    success: true,
    id,
    status
  });
});

// 5. POST /api/devices/register: Upsert device token
app.post<{
  Body: { token: string }
}>('/api/devices/register', async (request, reply) => {
  const { token } = request.body || {};

  if (!token || typeof token !== 'string') {
    return reply.status(400).send({
      error: 'Missing or invalid device token'
    });
  }

  DeviceRepo.upsert(token.trim());
  return reply.send({
    success: true,
    message: 'Device registered successfully'
  });
});

// 6. GET /api/devices: List count and masked tokens for dashboard
app.get('/api/devices', async (_request, reply) => {
  const tokens = DeviceRepo.getAllTokens();
  return reply.send({
    count: tokens.length,
    tokens: tokens.map(t => `${t.slice(0, 10)}...${t.slice(-6)}`)
  });
});

export { app };

if (process.env.NODE_ENV !== 'test') {
  const PORT = parseInt(process.env.PORT || '3000', 10);
  const HOST = process.env.HOST || '0.0.0.0';

  try {
    await app.listen({ port: PORT, host: HOST });
    console.log(`\n🚀 Remote Alarm Backend running at http://${HOST}:${PORT}`);
    console.log(`📱 Dashboard available at http://localhost:${PORT}\n`);
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
}
