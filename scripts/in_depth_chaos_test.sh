#!/usr/bin/env bash
set -e

SERVER_URL="http://localhost:3000"

echo "========================================================"
echo "Starting In-Depth Fault Injection & Chaos Test Suite"
echo "========================================================"

adb reverse tcp:3000 tcp:3000

# ------------------------------------------------------------------------------
# Test 1: Transient Server Failure (HTTP 500) Sync Purge Vulnerability
# ------------------------------------------------------------------------------
echo ""
echo "[Fault Injection 1/3] Testing Transient Server Failure Sync Behavior..."
# Create a valid test alarm first
TARGET_TIME=$(node -e 'console.log(new Date(Date.now() + 7200000).toISOString())')
CREATE_RES=$(curl -s -X POST "$SERVER_URL/api/alarms" \
  -H "Content-Type: application/json" \
  -d '{"target_time":"'"$TARGET_TIME"'","label":"chaos_vulnerability_probe","sound_tone":"chime","ramp_seconds":15}')
ALARM_ID=$(echo "$CREATE_RES" | node -e 'console.log(JSON.parse(require("fs").readFileSync(0, "utf-8")).id);')
echo "Baseline alarm created: $ALARM_ID"
sleep 2

# Inspect phone alarms before fault injection
echo "Checking phone active alarms..."
adb logcat -c

# Now simulate an invalid response or server error
echo "Probing mobile client response when server fails or returns malformed response..."
# We test if the mobile client distinguishes between an empty list [] and a network/server failure.
# In mobile/lib/services/backend_client.dart, fetchAllAlarms returns [] on catch (e) or non-200.
# If it returns [], syncWithBackend will iterate and prune all local alarms!

echo "Simulating server 500 error on /api/alarms..."
# Temporarily kill backend or block port to simulate 500/timeout
adb reverse --remove tcp:3000

# Force app sync by bringing to foreground
adb shell am start -n com.remotealarm.mobile/.MainActivity > /dev/null 2>&1
sleep 3

# Check logcat to see what happened during sync failure
SYNC_LOGS=$(adb logcat -d | grep -i -E "BackendClient|AlarmService|Pruned" | tail -n 20 || true)
echo "Mobile sync logs during simulated server failure:"
echo "$SYNC_LOGS"

# Restore reverse port
adb reverse tcp:3000 tcp:3000

# Clean up baseline alarm
curl -s -X DELETE "$SERVER_URL/api/alarms/$ALARM_ID" > /dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# Test 2: Poison Pill Malformed FCM Payloads
# ------------------------------------------------------------------------------
echo ""
echo "[Fault Injection 2/3] Injecting Malformed / Poison Pill Payloads..."

# Test server handling of poison pills
POISON_RES_1=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/api/alarms" \
  -H "Content-Type: application/json" \
  -d '{"target_time":"not-a-valid-date","label":"poison_date"}')
echo "Server response to invalid target_time: $POISON_RES_1 (Expected: 400)"

POISON_RES_2=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/api/alarms" \
  -H "Content-Type: application/json" \
  -d '{"target_time":"'"$TARGET_TIME"'","label":""}')
echo "Server response to empty label: $POISON_RES_2 (Expected: 400)"

POISON_RES_3=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL/api/alarms" \
  -H "Content-Type: application/json" \
  -d '{"target_time":"'"$TARGET_TIME"'","label":"valid","ramp_seconds":-999}')
echo "Server response to negative ramp_seconds: $POISON_RES_3"

# ------------------------------------------------------------------------------
# Test 3: SQL Injection / Extreme String Buffer Stress
# ------------------------------------------------------------------------------
echo ""
echo "[Fault Injection 3/3] SQL Injection & Huge Payload Stress..."
SQLI_LABEL="test'; DROP TABLE alarms; --"
SQLI_RES=$(curl -s -X POST "$SERVER_URL/api/alarms" \
  -H "Content-Type: application/json" \
  -d '{"target_time":"'"$TARGET_TIME"'","label":"'"$SQLI_LABEL"'"}')
SQLI_ID=$(echo "$SQLI_RES" | node -e 'try { console.log(JSON.parse(require("fs").readFileSync(0, "utf-8")).id); } catch(e){ console.log(""); }')
if [ -n "$SQLI_ID" ]; then
  echo "SQL injection payload safely parameterized. Alarm ID: $SQLI_ID"
  # Verify table is still alive
  CHECK_TABLE=$(curl -s "$SERVER_URL/api/alarms")
  if echo "$CHECK_TABLE" | grep -q "id"; then
    echo "Pass: SQLite table intact, injection sanitized."
  else
    echo "CRITICAL: Table dropped or inaccessible!"
  fi
  curl -s -X DELETE "$SERVER_URL/api/alarms/$SQLI_ID" > /dev/null 2>&1 || true
else
  echo "Server rejected SQL injection payload with response: $SQLI_RES"
fi

echo ""
echo "========================================================"
echo "In-Depth Chaos Suite Complete."
echo "========================================================"
