#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/maa-history-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PYTEST'
from pathlib import Path
import sys
out=Path(sys.argv[1]);source=Path('MeoAsstMac/Model/DepotHistoryStore.swift').read_text()
marker='// MARK: - App integration'
assert source.count(marker)==1
(out/'Store.swift').write_text(source[:source.index(marker)])
(out/'main.swift').write_text(Path('Tests/DepotHistoryStoreTests.swift').read_text())
PYTEST
xcrun swiftc MeoAsstMac/Model/InventoryTarget.swift "$test_dir/Store.swift" "$test_dir/main.swift" -o "$test_dir/tests"
"$test_dir/tests"
