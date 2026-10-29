#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/maa-fiammetta-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('MeoAsstMac/Task Configurations/LegacyConfigurations.swift').read_text()
start = source.index('extension InfrastConfiguration {')
end = source.index('\nextension ', start + 1)
Path(sys.argv[1]).write_text(source[start:end] + '\n' + Path('Tests/InfrastFiammettaTests.swift').read_text())
PY
xcrun swiftc Tests/InfrastFiammettaTestSupport.swift \
    'MeoAsstMac/Task Configurations/InfrastConfiguration.swift' \
    Packages/LegacyUserTasks/Sources/LegacyUserTasks/Infrast.swift \
    "$test_dir/main.swift" -o "$test_dir/fiammetta-tests"
"$test_dir/fiammetta-tests" "$@"
