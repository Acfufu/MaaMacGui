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
    /// 可注入映射表（评审 P13-1-R3 低5：恒等桩使映射失败分支零覆盖）——显式
    /// 命中的键返回表值（nil 值=映射失败哨兵），未命中键保持恒等；delay 拉宽
    /// 派生窗口供并发交错回归（中危-1）。
    nonisolated(unsafe) static var overrideMap: [String: String?]? = nil
    nonisolated(unsafe) static var mapDelayNanoseconds: UInt64 = 0
    func mapLevelCode(matching key: String) async -> String? {
        if Self.mapDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: Self.mapDelayNanoseconds)
        }
        if let map = Self.overrideMap, map.keys.contains(key) {
            return map[key] ?? nil
        }
        return key
    }
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
