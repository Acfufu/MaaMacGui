#!/bin/bash
# Capability-derivation matrix tests for CoreCapabilities.derive (P02.2).
# Compiles the production sources without launching the app or linking
# MaaCore: derivation only reads the resource tree, and its inputs come from
# FightConfiguration/SecretFrontConfiguration plus MAAClientChannel.
# P06.1 起 FightConfiguration 引用真实目录/活动层（StageCatalog 等），任务
# 桩面收缩为任务壳；MAAClientChannel 由脚本提取的真实定义提供（含 isGlobal）。
# The MAAViewModel refresh wiring is not compilable in this harness --
# verify the three call sites (loadResource/reloadResources defers and
# updateChannel) manually when touching them.
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$test_dir")"
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/maa-core-capabilities-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT

python3 - "$test_build_dir" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
core=Path('MeoAsstMac/Core/Maa.swift').read_text()
channel=Path('MeoAsstMac/Task Configurations/StartupConfiguration.swift').read_text()
p.joinpath('ActivityModels.swift').write_text('import Foundation\n'+core[core.index('struct MAAStageActivity:'):]+'\n'+channel[channel.index('enum MAAClientChannel:'):])
PY

xcrun swiftc -parse-as-library \
    "$test_build_dir/ActivityModels.swift" \
    "$repo_dir/MeoAsstMac/Core/CoreCapabilities.swift" \
    "$repo_dir/MeoAsstMac/Task Configurations/FightConfiguration.swift" \
    "$repo_dir/MeoAsstMac/Model/InventoryTarget.swift" \
    "$repo_dir/MeoAsstMac/Model/SecretFront.swift" \
    "$repo_dir/MeoAsstMac/Model/StageCatalog.swift" \
    "$repo_dir/MeoAsstMac/Model/StageActivity.swift" \
    "$repo_dir/MeoAsstMac/Model/FightStage.swift" \
    "$repo_dir/MeoAsstMac/Utils/HGCalendar.swift" \
    "$test_dir/CoreCapabilitiesTests.swift" \
    -module-cache-path "$test_build_dir/module-cache" \
    -o "$test_build_dir/core-capabilities-tests"
"$test_build_dir/core-capabilities-tests"
