#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# P06.1 起 FightConfiguration 的备选解析引用 StageCatalog；P06.2 补齐本套件
# 编译面（P06.1 全量扫描遗漏项）：目录判定源 + 真实 StageActivityContext +
# 提取的活动模型，与 run-fight-configuration-tests.sh 同一提取方式。
python3 - "$TEMP_DIR" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
core=Path('MeoAsstMac/Core/Maa.swift').read_text()
channel=Path('MeoAsstMac/Task Configurations/StartupConfiguration.swift').read_text()
p.joinpath('ActivityModels.swift').write_text('import Foundation\n'+core[core.index('struct MAAStageActivity:'):]+'\n'+channel[channel.index('enum MAAClientChannel:'):])
PY

xcrun swiftc -parse-as-library \
    "$TEMP_DIR/ActivityModels.swift" \
    MeoAsstMac/Model/InventoryTarget.swift \
    'MeoAsstMac/Task Configurations/FightConfiguration.swift' \
    MeoAsstMac/Model/StageCatalog.swift \
    MeoAsstMac/Model/StageActivity.swift \
    MeoAsstMac/Model/FightStage.swift \
    MeoAsstMac/Utils/HGCalendar.swift \
    Tests/InventoryTargetTestSupport.swift \
    Tests/InventoryTargetTests.swift \
    -o "$TEMP_DIR/inventory-tests"
"$TEMP_DIR/inventory-tests"
