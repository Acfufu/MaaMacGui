#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TEST_DIR=$(mktemp -d /tmp/maa-resource-update-network-tests.XXXXXX)
trap 'rm -rf "$TASK_TEST_DIR"' EXIT
swiftc -parse-as-library MeoAsstMac/Utils/ResourceUpdateNetwork.swift Tests/ResourceUpdateNetworkTests.swift -o "$TASK_TEST_DIR/tests"
"$TASK_TEST_DIR/tests"
