#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo "🧪 Running Remote Alarm Test Suite"
echo "========================================="

echo ""
echo "▶ Running Backend Tests (Fastify + SQLite + FCM)..."
cd "$ROOT_DIR/backend"
npm test

echo ""
echo "▶ Running Mobile Tests (Flutter + Alarm + IdMapper)..."
cd "$ROOT_DIR/mobile"
flutter test

echo ""
echo "========================================="
echo "✅ All Backend & Mobile Test Suites Passed!"
echo "========================================="
