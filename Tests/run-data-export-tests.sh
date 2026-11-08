#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/maa-data-export.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
cp Tests/DataExportTests.swift "$test_dir/main.swift"
xcrun swiftc MeoAsstMac/Model/InventoryTarget.swift MeoAsstMac/Model/DepotHistoryStore.swift MeoAsstMac/Model/OperBoxHistoryStore.swift MeoAsstMac/Model/OperBoxHistoryPayload.swift MeoAsstMac/Model/DataExport.swift "$test_dir/main.swift" -o "$test_dir/tests"
"$test_dir/tests"
