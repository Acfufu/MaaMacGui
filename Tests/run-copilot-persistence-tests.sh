#!/bin/bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$test_dir")"
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/maa-copilot-persistence-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT

# Same extraction contract as run-copilot-compile-tests.sh: the production
# model files are compiled verbatim; only app-level boundaries are stubbed so
# the suite stays self-contained (no MaaCore, no DerivedData). The stubbed
# MAAProvider maps stage names identically so set fixtures resolve without a
# Core mapping table.
cat > "$test_build_dir/CopilotPersistenceBoundaryStubs.swift" <<'EOF'
import Foundation

@propertyWrapper struct Defaults<Value: Equatable & Sendable> {
    private var storage: Value
    init(wrappedValue: Value, _ key: String) { storage = wrappedValue }
    var wrappedValue: Value {
        get { storage }
        set { storage = newValue }
    }
}

actor MAAProvider {
    static let shared = MAAProvider()
    func mapLevelCode(matching key: String) -> String? { key }
}

enum MAATaskType: String {
    case Copilot
    case SSSCopilot
    case ParadoxCopilot
}

extension URL {
    static let externalCopilotDirectory =
        URL(fileURLWithPath: "/tmp/maa-copilot-persistence-tests/external")
}
EOF

xcrun swiftc -parse-as-library -module-cache-path "$test_build_dir/module-cache" \
    "$repo_dir/MeoAsstMac/Task Configurations/CopilotConfiguration.swift" \
    "$repo_dir/MeoAsstMac/Task Configurations/CopilotPersistence.swift" \
    "$repo_dir/MeoAsstMac/Task Configurations/OperBoxAssistExport.swift" \
    "$repo_dir/MeoAsstMac/Model/MAACopilot.swift" \
    "$repo_dir/MeoAsstMac/Model/OperBoxHistoryPayload.swift" \
    "$repo_dir/MeoAsstMac/Utils/Codeable+JSON.swift" \
    "$repo_dir/MeoAsstMac/Utils/URL+contentType.swift" \
    "$test_build_dir/CopilotPersistenceBoundaryStubs.swift" \
    "$test_dir/CopilotPersistenceTests.swift" \
    -o "$test_build_dir/copilot-persistence-tests"
"$test_build_dir/copilot-persistence-tests"
