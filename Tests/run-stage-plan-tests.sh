#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/maa-stage-plan.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
core=Path('MeoAsstMac/Core/Maa.swift').read_text()
channel=Path('MeoAsstMac/Task Configurations/StartupConfiguration.swift').read_text()
p.joinpath('ActivityModels.swift').write_text('import Foundation\n'+core[core.index('struct MAAStageActivity:'):]+'\n'+channel[channel.index('enum MAAClientChannel:'):])
PY

xcrun swiftc Tests/StagePlanTests.swift \
  "MeoAsstMac/Task Configurations/FightConfiguration.swift" \
  MeoAsstMac/Model/InventoryTarget.swift \
  MeoAsstMac/Model/StageCatalog.swift \
  MeoAsstMac/Model/StageActivity.swift MeoAsstMac/Model/FightStage.swift \
  MeoAsstMac/Utils/HGCalendar.swift \
  "$test_dir/ActivityModels.swift" -o "$test_dir/tests"
"$test_dir/tests" "$PWD/Tests/Fixtures/StageActivitySample.json"
