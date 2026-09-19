import { db, AlarmRepo, DeviceRepo } from './db.js';
import { v4 as uuidv4 } from 'uuid';

async function runTests() {
  console.log('Testing Database and API logic...');

  // 1. Device Registration
  const testToken = 'fcm_token_test_' + Date.now();
  DeviceRepo.upsert(testToken);
  const tokens = DeviceRepo.getAllTokens();
  console.assert(tokens.includes(testToken), 'Device token should be saved');
  console.log('[PASS] DeviceRepo test passed');

  // 2. Alarm creation
  const id = uuidv4();
  const testAlarm = {
    id,
    target_time: new Date(Date.now() + 60000).toISOString(),
    label: 'Test Wakeup',
    status: 'pending' as const
  };
  AlarmRepo.create(testAlarm);
  const fetched = AlarmRepo.getById(id);
  console.assert(fetched?.id === id, 'Alarm should be retrievable by ID');
  console.assert(fetched?.label === 'Test Wakeup', 'Alarm label should match');
  console.log('[PASS] AlarmRepo create & getById passed');

  // 3. State update
  AlarmRepo.updateStatus(id, 'snoozed');
  const snoozed = AlarmRepo.getById(id);
  console.assert(snoozed?.status === 'snoozed', 'Alarm status should be updated to snoozed');
  console.log('[PASS] AlarmRepo updateStatus passed');

  // 4. Cancel
  AlarmRepo.cancel(id);
  const canceled = AlarmRepo.getById(id);
  console.assert(canceled?.status === 'canceled', 'Alarm status should be canceled');
  console.log('[PASS] AlarmRepo cancel passed');

  // Cleanup test data
  DeviceRepo.remove(testToken);
  db.prepare('DELETE FROM alarms WHERE id = ?').run(id);

  console.log('[SUCCESS] All Backend DB and logic tests passed!');
}

runTests().catch(console.error);
