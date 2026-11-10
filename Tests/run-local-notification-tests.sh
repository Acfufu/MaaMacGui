#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TEST_DIR=$(mktemp -d /tmp/maa-local-notification-tests.XXXXXX)
trap 'rm -rf "$TASK_TEST_DIR"' EXIT
swiftc -parse-as-library MeoAsstMac/Utils/LocalNotificationService.swift Tests/LocalNotificationTests.swift -o "$TASK_TEST_DIR/tests"
"$TASK_TEST_DIR/tests"
