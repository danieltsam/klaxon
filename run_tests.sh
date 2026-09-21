#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo "Running Remote Alarm Test Suite"
echo "========================================="

echo ""
echo "[1/3] Running Backend Tests (Fastify + SQLite Memory + FCM + Sync Contracts)..."
cd "$ROOT_DIR/backend"
npm test

echo ""
echo "[2/3] Running Mobile Tests (Flutter + Alarm + IdMapper + Reconnection)..."
cd "$ROOT_DIR/mobile"
flutter test

echo ""
echo "[3/3] Running Clients Tests (Core API Client + Time Parser + Formatters)..."
cd "$ROOT_DIR/clients"
npm test

if [ "$1" == "--with-device" ] || [ "$2" == "--with-device" ]; then
  echo ""
  echo "[Optional] Running Live Device Sync Test via ADB..."
  "$ROOT_DIR/scripts/test_live_device_sync.sh"
fi

if [ "$1" == "--with-chaos" ] || [ "$2" == "--with-chaos" ]; then
  echo ""
  echo "[Optional 1/2] Running Chaos Engineering Test Suite via ADB..."
  "$ROOT_DIR/scripts/chaos_engineering_test.sh"

  echo ""
  echo "[Optional 2/2] Running In-Depth Fault Injection Test Suite..."
  "$ROOT_DIR/scripts/in_depth_chaos_test.sh"
fi

echo ""
echo "========================================="
echo "All Automated Test Suites Passed Successfully!"
echo "========================================="
