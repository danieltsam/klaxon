#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo "Running Remote Alarm Test Suite"
echo "========================================="

echo ""
echo "[1/2] Running Backend Tests (Fastify + SQLite Memory + FCM + Sync Contracts)..."
cd "$ROOT_DIR/backend"
npm test

echo ""
echo "[2/2] Running Mobile Tests (Flutter + Alarm + IdMapper + Reconnection)..."
cd "$ROOT_DIR/mobile"
flutter test

if [ "$1" == "--with-device" ]; then
  echo ""
  echo "[Optional] Running Live Device Sync Test via ADB..."
  "$ROOT_DIR/scripts/test_live_device_sync.sh"
fi

echo ""
echo "========================================="
echo "All Automated Test Suites Passed Successfully!"
echo "========================================="
