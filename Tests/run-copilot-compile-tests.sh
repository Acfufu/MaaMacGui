#!/bin/bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$test_dir")"
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/maa-copilot-compile-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT

# The production model files below are compiled verbatim; only app-level
# boundaries are stubbed so the suite stays self-contained (no MaaCore, no
# DerivedData) and ci.yml can pick it up with the plain Tests/run-*.sh sweep.
cat > "$test_build_dir/CopilotBoundaryStubs.swift" <<'EOF'
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
    func mapLevelCode(matching key: String) -> String? { nil }
}

enum MAATaskType: String {
    case Copilot
    case SSSCopilot
    case ParadoxCopilot
}

extension URL {
    static let externalCopilotDirectory =
        URL(fileURLWithPath: "/tmp/maa-copilot-compile-tests/external")
}
EOF

xcrun swiftc -parse-as-library -module-cache-path "$test_build_dir/module-cache" \
    "$repo_dir/MeoAsstMac/Task Configurations/CopilotConfiguration.swift" \
    "$repo_dir/MeoAsstMac/Model/MAACopilot.swift" \
    "$repo_dir/MeoAsstMac/Utils/Codeable+JSON.swift" \
    "$repo_dir/MeoAsstMac/Utils/URL+contentType.swift" \
    "$test_build_dir/CopilotBoundaryStubs.swift" \
    "$test_dir/CopilotCompileTests.swift" \
    -o "$test_build_dir/copilot-compile-tests"
"$test_build_dir/copilot-compile-tests" \
    "$test_dir/Fixtures/CopilotRegularStage.json" \
    "$test_dir/Fixtures/CopilotSSSStage.json" \
    "$test_dir/Fixtures/CopilotParadoxStage.json"
