#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/maa-user-data-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYTEST'
from pathlib import Path
import sys
s=Path('MeoAsstMac/Core/Maa.swift').read_text();marker='    func appendTask(type: MAATaskType, params: String) throws -> Int32 {'
assert s.count(marker)==1
start=s.index(marker);body=s.index('{',start);depth=0
for end in range(body,len(s)):
 if s[end]=='{':depth+=1
 elif s[end]=='}':
  depth-=1
  if depth==0:break
method=s[start:end+1]
test=Path('Tests/UserDataUpdateTests.swift').read_text();assert test.count('// NATIVE_APPEND')==1
Path(sys.argv[1]).write_text(test.replace('// NATIVE_APPEND',method))
PYTEST
xcrun swiftc MeoAsstMac/Model/InventoryTarget.swift MeoAsstMac/Utils/HGCalendar.swift MeoAsstMac/Model/DepotHistoryStore.swift MeoAsstMac/Model/OperBoxHistoryStore.swift MeoAsstMac/Model/OperBoxHistoryPayload.swift MeoAsstMac/Model/UserDataUpdateRun.swift 'MeoAsstMac/Task Configurations/UserDataUpdateConfiguration.swift' "$test_dir/main.swift" -o "$test_dir/tests"
"$test_dir/tests"
