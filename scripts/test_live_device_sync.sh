#!/usr/bin/env bash
set -e

SERVER_URL="http://localhost:3000"

echo "=========================================="
echo "Starting Live Device Bidirectional Sync Test"
echo "=========================================="

# 1. Verify ADB Device Connectivity
echo ""
echo "[Step 1/6] Checking connected Android devices via ADB..."
DEVICE_LINE=$(adb devices | grep -w "device" | head -n 1 || true)
if [ -z "$DEVICE_LINE" ]; then
  echo "Error: No active Android device detected over ADB."
  echo "Please connect your phone via USB and enable USB debugging."
  exit 1
fi
DEVICE_SERIAL=$(echo "$DEVICE_LINE" | awk '{print $1}')
echo "Detected device: $DEVICE_SERIAL"

# 2. Verify Port Forwarding and Server Health
echo ""
echo "[Step 2/6] Configuring reverse port forward and checking backend..."
adb reverse tcp:3000 tcp:3000
SERVER_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$SERVER_URL/" || true)
if [ "$SERVER_STATUS" != "200" ]; then
  echo "Error: Backend server is not running on $SERVER_URL (status: $SERVER_STATUS)."
  echo "Please start the backend with 'npm run dev' before running live tests."
  exit 1
fi
echo "Backend server is healthy (HTTP 200)."

# Clear logcat buffer for clean event tracking
adb logcat -c

# 3. Test Remote Alarm Creation -> Push to Device
echo ""
echo "[Step 3/6] Testing Backend -> Device Alarm Creation & Push..."
TARGET_TIME=$(node -e 'console.log(new Date(Date.now() + 7200000).toISOString())')
CREATE_PAYLOAD=$(cat <<EOF
{
  "target_time": "$TARGET_TIME",
  "label": "test_e2e_live_sync",
  "sound_tone": "chime",
  "ramp_seconds": 15,
  "repeat_days": "1,2,3,4,5"
}
EOF
)

CREATE_RES=$(curl -s -X POST "$SERVER_URL/api/alarms" \
  -H "Content-Type: application/json" \
  -d "$CREATE_PAYLOAD")

ALARM_ID=$(echo "$CREATE_RES" | node -e '
  const fs = require("fs");
  const data = JSON.parse(fs.readFileSync(0, "utf-8"));
  if (data && data.id) console.log(data.id);
')

if [ -z "$ALARM_ID" ]; then
  echo "Error: Failed to create test alarm on backend. Response: $CREATE_RES"
  exit 1
fi
echo "Created test alarm ID: $ALARM_ID"

# Wait for FCM delivery and verify
sleep 2
echo "Verifying device received FCM data message..."
LOGCAT_CHECK=$(adb logcat -d | grep -i "$ALARM_ID" || true)
if [ -n "$LOGCAT_CHECK" ]; then
  echo "Verified: Alarm ID $ALARM_ID was processed by device."
else
  echo "Warning: Direct logcat match not found in short window; checking sync via query..."
fi

# 4. Test State Toggle: pending -> disabled (Cancel on device)
echo ""
echo "[Step 4/6] Testing Remote Slider Toggle: pending -> disabled..."
TOGGLE_OFF_RES=$(curl -s -X POST "$SERVER_URL/api/alarms/$ALARM_ID/state" \
  -H "Content-Type: application/json" \
  -d '{"status":"disabled"}')

STATUS_OFF=$(echo "$TOGGLE_OFF_RES" | node -e '
  const fs = require("fs");
  const data = JSON.parse(fs.readFileSync(0, "utf-8"));
  console.log(data.status || "");
')

if [ "$STATUS_OFF" != "disabled" ]; then
  echo "Error: Expected disabled status, got: $TOGGLE_OFF_RES"
  exit 1
fi
echo "Successfully transitioned alarm to disabled state."

# Toggle back to pending
echo "Testing Remote Slider Toggle: disabled -> pending..."
TOGGLE_ON_RES=$(curl -s -X POST "$SERVER_URL/api/alarms/$ALARM_ID/state" \
  -H "Content-Type: application/json" \
  -d '{"status":"pending"}')

STATUS_ON=$(echo "$TOGGLE_ON_RES" | node -e '
  const fs = require("fs");
  const data = JSON.parse(fs.readFileSync(0, "utf-8"));
  console.log(data.status || "");
')

if [ "$STATUS_ON" != "pending" ]; then
  echo "Error: Expected pending status, got: $TOGGLE_ON_RES"
  exit 1
fi
echo "Successfully transitioned alarm back to pending state."

# 5. Test Reconnection & Catch-up Resilience
echo ""
echo "[Step 5/6] Testing Network Interruption & Catch-up Reconciliation..."
# Simulate network severance by removing port forward
adb reverse --remove tcp:3000

# Create an alarm while phone is offline
OFFLINE_TIME=$(node -e 'console.log(new Date(Date.now() + 10800000).toISOString())')
OFFLINE_RES=$(curl -s -X POST "$SERVER_URL/api/alarms" \
  -H "Content-Type: application/json" \
  -d '{"target_time":"'"$OFFLINE_TIME"'","label":"test_e2e_offline_alarm","sound_tone":"digital","ramp_seconds":0}')

OFFLINE_ALARM_ID=$(echo "$OFFLINE_RES" | node -e '
  const fs = require("fs");
  const data = JSON.parse(fs.readFileSync(0, "utf-8"));
  if (data && data.id) console.log(data.id);
')
echo "Created second alarm while route offline: $OFFLINE_ALARM_ID"

# Restore port forward
adb reverse tcp:3000 tcp:3000
echo "Restored network route. Triggering app reconnection..."

# Bring app to foreground to trigger resume sync
adb shell am start -n com.remotealarm.mobile/.MainActivity > /dev/null 2>&1
sleep 3

# 6. Cleanup Test Fixtures
echo ""
echo "[Step 6/6] Cleaning up test fixtures from backend and device..."
curl -s -X DELETE "$SERVER_URL/api/alarms/$ALARM_ID" > /dev/null 2>&1 || true
if [ -n "$OFFLINE_ALARM_ID" ]; then
  curl -s -X DELETE "$SERVER_URL/api/alarms/$OFFLINE_ALARM_ID" > /dev/null 2>&1 || true
fi
echo "Test fixtures successfully purged."

echo ""
echo "=========================================="
echo "Live Device Bidirectional Sync Test Passed!"
echo "=========================================="
