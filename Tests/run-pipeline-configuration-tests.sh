#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/maa-pipeline-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYTEST'
from pathlib import Path
import sys
source = Path('MeoAsstMac/Model/MAATask.swift').read_text()
model = source[source.index('enum MAATask:'):source.index('let defaultTaskConfigurations:')]
daily = source[source.index('struct DailyTask:'):source.index('extension Array where Element == DailyTask')]
placeholders = 'struct PlaceholderConfiguration: Codable, Equatable {}\n'
for name in ['Startup','Closedown','Recruit','Infrast','Fight','Mall','Award','SwitchTheme','Roguelike','Reclamation']:
    placeholders += 'typealias ' + name + 'Configuration = PlaceholderConfiguration\n'
Path(sys.argv[1]).write_text(placeholders + model + daily + Path('Tests/PipelineConfigurationTests.swift').read_text())
PYTEST
xcrun swiftc MeoAsstMac/Model/InventoryTarget.swift MeoAsstMac/Utils/HGCalendar.swift 'MeoAsstMac/Task Configurations/UserDataUpdateConfiguration.swift' 'MeoAsstMac/Task Configurations/CustomConfiguration.swift' "$test_dir/main.swift" -o "$test_dir/tests"
"$test_dir/tests"
