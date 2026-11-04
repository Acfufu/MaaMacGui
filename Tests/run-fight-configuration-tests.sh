#!/bin/bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$test_dir")"
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/maa-fight-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT

# P06.1 起 FightConfiguration 的备选解析引用 StageCatalog：套件编译面随之
# 扩展（目录判定源 + 真实 StageActivityContext + 提取的活动模型）。
python3 - "$test_build_dir" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
core=Path('MeoAsstMac/Core/Maa.swift').read_text()
channel=Path('MeoAsstMac/Task Configurations/StartupConfiguration.swift').read_text()
p.joinpath('ActivityModels.swift').write_text('import Foundation\n'+core[core.index('struct MAAStageActivity:'):]+'\n'+channel[channel.index('enum MAAClientChannel:'):])
PY

xcrun swiftc -parse-as-library \
    "$repo_dir/MeoAsstMac/Task Configurations/FightConfiguration.swift" \
    "$repo_dir/MeoAsstMac/Model/InventoryTarget.swift" \
    "$repo_dir/MeoAsstMac/Model/StageCatalog.swift" \
    "$repo_dir/MeoAsstMac/Model/StageActivity.swift" \
    "$repo_dir/MeoAsstMac/Model/FightStage.swift" \
    "$repo_dir/MeoAsstMac/Utils/HGCalendar.swift" \
    "$test_build_dir/ActivityModels.swift" \
    "$test_dir/FightConfigurationTests.swift" \
    -o "$test_build_dir/fight-tests"
"$test_build_dir/fight-tests"
