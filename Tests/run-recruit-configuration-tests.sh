#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/maa-recruit-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
# Production binding-chain contract (P11-4-R3 高-1): the showPotential switch
# must live on the tool page (RecruitView.configView) bound to the SAME
# viewModel.recruitConfig object the render gate and onChange read — the daily
# task settings face writes a config object whose showPotential has no
# consumer (placebo switch, removed in P11.7). RecruitView is a SwiftUI view
# outside this suite's compile face, so the wiring is pinned by fail-loudly
# source anchors.
recruit_view="MeoAsstMac/Views/RecruitView.swift"
settings_view="MeoAsstMac/Configuration Views/RecruitSettingsView.swift"
anchor() {
    if ! grep -qF -- "$2" "$1"; then
        echo "FAIL: binding anchor missing ($3): $2" >&2
        exit 1
    fi
}
anchor "$recruit_view" 'Toggle("显示已持有干员潜能", isOn: $viewModel.recruitConfig.showPotential)' "settings-gate same source"
anchor "$recruit_view" '.onChange(of: viewModel.recruitConfig.showPotential)' "gate onChange source"
anchor "$recruit_view" 'showPotential: viewModel.recruitConfig.showPotential' "render gate source"
if grep -qF '$config.showPotential' "$settings_view"; then
    echo "FAIL: placebo showPotential binding must not return to the daily task settings face" >&2
    exit 1
fi
# Compile the actual fileprivate initializer together with its test callers.
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('MeoAsstMac/Task Configurations/LegacyConfigurations.swift').read_text()
start = source.index('extension RecruitConfiguration {')
end = source.index('\nextension ', start + 1)
Path(sys.argv[1]).write_text(source[start:end] + '\n' + Path('Tests/RecruitConfigurationTests.swift').read_text())
PY
xcrun swiftc \
    Tests/RecruitConfigurationTestSupport.swift \
    'MeoAsstMac/Task Configurations/RecruitConfiguration.swift' \
    'MeoAsstMac/Model/MAARecruit.swift' \
    Packages/LegacyUserTasks/Sources/LegacyUserTasks/Recruit.swift \
    "$test_dir/main.swift" -o "$test_dir/recruit-tests"
"$test_dir/recruit-tests" "$@"
