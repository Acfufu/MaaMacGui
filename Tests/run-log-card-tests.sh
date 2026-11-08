#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TEST_DIR=$(mktemp -d /tmp/maa-log-card-tests.XXXXXX)
trap 'rm -rf "$TASK_TEST_DIR"' EXIT
# 提取策略（pipeline/profile-patch harness 先例）：MAATask.swift 只取 enum MAATask +
# struct DailyTask + Array 扩展前段（含 D08 moved）；配置类型 typealias 指向占位。
python3 - "$TASK_TEST_DIR/main.swift" << 'PYTEST'
from pathlib import Path
import sys
source = Path('MeoAsstMac/Model/MAATask.swift').read_text()
model = source[source.index('enum MAATask:'):source.index('let defaultTaskConfigurations:')]
daily = source[source.index('struct DailyTask:'):source.index('extension Array where Element == DailyTask')]
ext = source[source.index('extension Array where Element == DailyTask'):]
ext = ext[:ext.index('    mutating func append')] + '}\n'
prefix = (
    'import Foundation\n'
    'enum MAATaskType: String {\n'
    '    case StartUp, CloseDown, Recruit, Infrast, Fight, Mall, Award, SwitchTheme\n'
    '    case Roguelike, Copilot, SSSCopilot, ParadoxCopilot, Depot, Reclamation\n'
    '    case VideoRecognition, OperBox, OperProgress, UserDataUpdate, DepotMaintain, Custom\n'
    '}\n'
    'struct PlaceholderConfiguration: Codable, Equatable {}\n'
    'protocol MAATaskConfiguration: Codable, Hashable {\n'
    '    associatedtype Params: Encodable\n'
    '    var params: Params { get }\n'
    '    var type: MAATaskType { get }\n'
    '    var projectedTask: MAATask { get }\n'
    '}\n'
    'extension PlaceholderConfiguration: MAATaskConfiguration {\n'
    '    var params: PlaceholderConfiguration { self }\n'
    '    var type: MAATaskType { .Custom }\n'
    '    var projectedTask: MAATask { .custom(.init()) }\n'
    '}\n'
)
for name in ['Startup', 'Closedown', 'Recruit', 'Infrast', 'Fight', 'Mall', 'Award',
             'SwitchTheme', 'Roguelike', 'Reclamation', 'Custom', 'OperProgress',
             'UserDataUpdate', 'DepotMaintain']:
    prefix += 'typealias ' + name + 'Configuration = PlaceholderConfiguration\n'
Path(sys.argv[1]).write_text(prefix + model + daily + ext + Path('Tests/LogCardBuilderTests.swift').read_text())
PYTEST
swiftc -parse-as-library \
    MeoAsstMac/Model/MAALog.swift \
    MeoAsstMac/Model/LogCardBuilder.swift \
    "$TASK_TEST_DIR/main.swift" \
    -o "$TASK_TEST_DIR/tests"
"$TASK_TEST_DIR/tests"
