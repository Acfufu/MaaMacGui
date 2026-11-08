#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TEST_DIR=$(mktemp -d /tmp/maa-post-action-tests.XXXXXX)
trap 'rm -rf "$TASK_TEST_DIR"' EXIT
swiftc -parse-as-library MeoAsstMac/RunHooks/PostActionRunner.swift Tests/PostActionTests.swift -o "$TASK_TEST_DIR/tests"
"$TASK_TEST_DIR/tests"
