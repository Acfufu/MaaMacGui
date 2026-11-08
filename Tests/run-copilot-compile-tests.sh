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
    "$repo_dir/MeoAsstMac/Task Configurations/CopilotPersistence.swift" \
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

# P13-[f]（快照 82 清单②裁定：随 WPF 对齐，2026-11-09）: C08 编辑面技能
# 0-3/新行默认 0——WPF CopilotView.xaml:374-385 NumericUpDown 0-3 +
# CopilotViewModel.cs:670 默认 0。CopilotView.swift 在套件编译面之外
# （SwiftUI 视图），生产绑定以 fail-loudly 源锚点钉死（VRI 套件先例）。
view="$repo_dir/MeoAsstMac/Views/CopilotView.swift"
anchor() {
    if ! grep -qF -- "$2" "$view"; then
        echo "FAIL: P13-[f] anchor missing ($1): $2" >&2
        exit 1
    fi
}
anchor "skill picker spans 0-3" "ForEach(0...3, id: \\.self)"
anchor "new unit defaults to skill 0" "config.user_additional.append(.init(name: \"\", skill: 0))"
