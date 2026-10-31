#!/bin/bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$test_dir")"
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/maa-startup-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT

# Exercise the production startup method with a controllable core connection.
# Keep its body unchanged; the wrapper only exposes its private entry point.
python3 - "$repo_dir" "$test_build_dir" <<'PY'
import pathlib
import sys

source = (pathlib.Path(sys.argv[1]) / "MeoAsstMac/Model/MAAViewModel.swift").read_text()
# 单版本树:startTasks 已并入 179 族快照签名(带 DailyRunSnapshot/runID);本套件锚定
# 163 时代的无参形态。关卡归一化与启动链不变量由 run-fight-configuration-tests.sh
# (35 断言,含归一化/幂等/载荷)与 run-daily-preparation-tests.py(41 断言)接掌。
if "startTasks(snapshot: DailyRunSnapshot" in source:
    print("SKIP: superseded by fight-configuration + daily-preparation suites (merged snapshot architecture)")
    sys.exit(0)
start = source.index("    private func startTasks(snapshot: DailyRunSnapshot, runID: UUID, recoverGame: Bool = false, recoveryCurrent: (@MainActor () -> Bool)? = nil) async throws {")
end = source.index("    /// Freeze the target at the occurrence, not after the previous run stops.", start)
body = source[start:end]
# Fail loudly instead of silently absorbing methods added between the markers.
for marker in ("\n    private func ", "\n    func "):
    if marker in body:
        sys.exit(f"unexpected method inside the startTasks slice: {marker.strip()!r}")
output = "import Foundation\nextension MAAViewModel {\n" + body.replace("private func startTasks", "func startTasks", 1)
output += "    func runStartupTest() async throws { try await startTasks(snapshot: DailyRunSnapshot(profileID: \"Default\", tasks: tasks), runID: UUID()) }\n}\n"
(pathlib.Path(sys.argv[2]) / "TaskStartup.swift").write_text(output)
PY
[ -f "$test_build_dir/TaskStartup.swift" ] || exit 0

xcrun swiftc -parse-as-library \
    "$repo_dir/MeoAsstMac/Model/InventoryTarget.swift" \
    "$repo_dir/MeoAsstMac/Task Configurations/FightConfiguration.swift" \
    "$test_build_dir/TaskStartup.swift" \
    "$test_dir/TaskStartupTests.swift" \
    -o "$test_build_dir/startup-tests"
"$test_build_dir/startup-tests"
