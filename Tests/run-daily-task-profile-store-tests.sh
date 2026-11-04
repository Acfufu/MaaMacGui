#!/bin/bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$test_dir")"
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/maa-profile-store-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT
cd "$repo_dir"

# Stitch a self-contained entry file: the DailyTask model plus both profile
# store test files (the multi-profile suite defines the shared check()).
python3 - "$test_build_dir/main.swift" <<'PY'
from pathlib import Path
import sys
tasks = Path('MeoAsstMac/Model/MAATask.swift').read_text()
daily_task = tasks[tasks.index('struct DailyTask:'):tasks.index('\nextension DailyTask {')]
Path(sys.argv[1]).write_text(
    daily_task + '\n'
    + Path('Tests/ProfileStoreTests.swift').read_text() + '\n'
    + Path('Tests/DailyTaskProfileStoreTests.swift').read_text())
PY
xcrun swiftc Tests/InfrastFiammettaTestSupport.swift \
    'MeoAsstMac/Task Configurations/InfrastConfiguration.swift' \
    MeoAsstMac/Model/MAAInfrast.swift \
    MeoAsstMac/Model/DailyTaskProfileStore.swift \
    Tests/Fixtures/PreFiammettaInfrastConfiguration.swift \
    "$test_build_dir/main.swift" -o "$test_build_dir/profile-store-tests"
"$test_build_dir/profile-store-tests" "$@"
