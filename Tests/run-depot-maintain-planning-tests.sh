#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/maa-depot-maintain.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

# Production binding-chain contract (P12-2-R3 高-1/中-1): the plan editor's
# delete affordance and manual stage-code toggle live in DepotMaintainSettingsView
# (a SwiftUI view outside this suite's compile face), so their wiring is pinned
# by fail-loudly source anchors. Any change to the entry surface must keep these
# anchors true.
editor="MeoAsstMac/Configuration Views/DepotMaintainSettingsView.swift"
anchor() {
    if ! grep -qF -- "$2" "$editor"; then
        echo "FAIL: binding anchor missing ($1): $2" >&2
        exit 1
    fi
}
anchor "per-row delete writes config.plans" 'config.plans.remove(at: index)'
anchor "manual stage toggle writes config.isStageManually" 'Toggle("手动输入关卡名", isOn: $config.isStageManually)'
anchor "manual TextField reachable via toggle" 'config.isStageManually || isStoredOutsideCatalog'

# P12.1：规划核心引用 FightConfiguration（合成下发参数）与活动窗口模型，
# 编译面与 run-stage-plan-tests 同族（Core/Startup 模型切片补齐依赖）。
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
core=Path('MeoAsstMac/Core/Maa.swift').read_text()
channel=Path('MeoAsstMac/Task Configurations/StartupConfiguration.swift').read_text()
p.joinpath('ActivityModels.swift').write_text('import Foundation\n'+core[core.index('struct MAAStageActivity:'):]+'\n'+channel[channel.index('enum MAAClientChannel:'):])
p.joinpath('main.swift').write_text(Path('Tests/DepotMaintainPlanningTests.swift').read_text())
PY

xcrun swiftc "$test_dir/main.swift" \
  "MeoAsstMac/Task Configurations/FightConfiguration.swift" \
  "MeoAsstMac/Task Configurations/DepotMaintainConfiguration.swift" \
  MeoAsstMac/Model/DepotMaintainPlanner.swift \
  MeoAsstMac/Model/InventoryTarget.swift \
  MeoAsstMac/Model/StageCatalog.swift \
  MeoAsstMac/Model/StageActivity.swift MeoAsstMac/Model/FightStage.swift \
  MeoAsstMac/Utils/HGCalendar.swift \
  "$test_dir/ActivityModels.swift" -o "$test_dir/tests"
"$test_dir/tests" "$PWD/Tests/Fixtures/StageActivitySample.json"
