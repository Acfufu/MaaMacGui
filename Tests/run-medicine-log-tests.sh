#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/maa-medicine-log.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PYTHON'
from pathlib import Path
import sys
p = Path(sys.argv[1])
core = Path('MeoAsstMac/Core/Maa.swift').read_text()
channel = Path('MeoAsstMac/Task Configurations/StartupConfiguration.swift').read_text()
p.joinpath('ActivityModels.swift').write_text('import Foundation\n' + core[core.index('struct MAAStageActivity:'):] + channel[channel.index('enum MAAClientChannel:'):])
model = Path('MeoAsstMac/Model/MAAViewModel.swift').read_text()
func_start = model.index('private func startTasks(snapshot:')
loop_start = model.index('\n            for task in runTasks {', func_start)
end = model.index('\n            // Appending crosses actors.', loop_start)
start = loop_start + 1
# Execute the production enqueue loop with a recording Core boundary. Only the
# clock is injected so the regression does not depend on a live activity.
enqueue = model[start:end].replace('Date.now', 'now').replace('runTasks', 'tasks')
import re as _re
enqueue = _re.sub(r'\n *achievementEvents\.register[^\n]*', '', enqueue, count=1)
# 179 族恢复门控与成就登记不在本套件边界内,剥离后由各自套件覆盖。
enqueue = _re.sub(r'\n *if recoverGame, recoveryCurrent\?\(\) == false \{ throw CancellationError\(\) \}', '', enqueue, count=1)
enqueue = _re.sub(r'\n *try Task\.checkCancellation\(\)', '', enqueue, count=1)
enqueue = _re.sub(r'\n *achievementEvents\.register[^\n]*', '', enqueue, count=1)
enqueue = _re.sub(r'\n *inventoryFightIDs\.insert[^\n]*', '', enqueue, count=1)
enqueue = _re.sub(r'\n *appendedAnyTask = true', '', enqueue, count=1)
message = Path('MeoAsstMac/Core/MaaMessage.swift').read_text()
start = message.index('            let expiry: String', message.index('case "UseMedicine":'))
end = message.index('            if medicine.is_expiring {', start)
expiry = message[start:end]
start = model.index('        taskIDMap.removeAll()')
end = model.index('        guard requireConnect', start)
reset = model[start:end]
p.joinpath('ProductionLogPath.swift').write_text('import Foundation\nextension MedicineLogHarness {\nfunc enqueue() async throws {\n' + enqueue + '}\nfunc expiryText(coreID: Int32?) -> String {\nlet info = CallbackInfo(taskid: coreID)\n' + expiry + 'return expiry\n}\nfunc resetQueue() {\n' + reset + '}\n}\n')
PYTHON
xcrun swiftc Tests/ActivityMedicineTestSupport.swift \
  'MeoAsstMac/Task Configurations/FightConfiguration.swift' \
  MeoAsstMac/Model/StageActivity.swift MeoAsstMac/Utils/HGCalendar.swift MeoAsstMac/Model/InventoryTarget.swift \
  "$test_dir/ActivityModels.swift" "$test_dir/ProductionLogPath.swift" \
  Tests/MedicineLogTests.swift -o "$test_dir/tests"
"$test_dir/tests"
