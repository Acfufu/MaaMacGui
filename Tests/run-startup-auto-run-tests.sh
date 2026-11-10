#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TEST_DIR=$(mktemp -d /tmp/maa-startup-auto-run-tests.XXXXXX)
trap 'rm -rf "$TASK_TEST_DIR"' EXIT
swiftc -parse-as-library MeoAsstMac/Model/StartupAutoRun.swift MeoAsstMac/Utils/MainWindowVisibility.swift Tests/StartupAutoRunTests.swift -o "$TASK_TEST_DIR/tests"
"$TASK_TEST_DIR/tests"
