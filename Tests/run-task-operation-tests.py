#!/usr/bin/env python3
"""Compile production entry points verbatim with a controllable core/connection boundary.
No game, real MAA handle, user defaults, or application container is touched.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source_root = Path(os.environ.get('MAA_TEST_SOURCE_ROOT', root))
model = (source_root / 'MeoAsstMac/Model/MAAViewModel.swift').read_text()
bridge = (source_root / 'MeoAsstMac/Model/NewViewModel.swift').read_text()
menu = (source_root / 'MeoAsstMac/Views/TaskButtons.swift').read_text()

def declaration(source, pattern):
    match = re.search(pattern, source, re.M)
    assert match, pattern
    start = source.index('{', match.start())
    depth = 1
    end = start + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    return source[match.start():end]

parts = [declaration(model, r'^    enum Status:')]
parts += [re.search(r'^    @Published private\(set\) var status = .*$', model, re.M)[0]]
parts += [re.search(r'^    (?:@Published private\(set\) |private )var isStartStopInFlight = .*$', model, re.M)[0]]
for name in ['canStartTasks', 'beginTaskOperation']:
    pattern = rf'^    (?:private )?(?:func|var) {name}\b'
    if re.search(pattern, model, re.M): parts.append(declaration(model, pattern))
for name in ['stop', 'tryStartTasks', 'startTasks', 'handleEarlyReturn', 'startCopilot', 'recognizeRecruit',
             'recognizeDepot', 'recognizeVideo', 'recognizeOperBox', 'gachaPoll', 'miniGame']:
    parts.append(declaration(model, rf'^    (?:private )?func {name}\b'))
# Read the actual SwiftUI menu predicate, rather than duplicating its intended logic.
predicate = re.search(r'\.disabled\(([^\n]+)\)', menu)[1]
parts += [f'    var menuStartDisabled: Bool {{ {predicate.replace("viewModel.", "")} }}']
model_source = '\n'.join(parts)
bridge_source = declaration(bridge, r'^    nonisolated\(nonsending\) func startCopilot\(')
support = (root / 'Tests/TaskOperationTestSupport.swift').read_text()
support = support.replace('// PRODUCTION_MODEL_MEMBERS', model_source)
support = support.replace('// PRODUCTION_COPILOT_BRIDGE', bridge_source)
bridge_state = declaration(bridge, r'^    @MainActor var status:')
if 'var canStartTasks:' in bridge:
    bridge_state += '\n' + declaration(bridge, r'^    @MainActor var canStartTasks:')
subscriptions = '\n'.join(re.findall(r'        parent\.\$\w+\.sink.*?        \.store\(in: &cancellables\)', bridge, re.S))
support = support.replace('// PRODUCTION_BRIDGE_STATE', bridge_state)
support = support.replace('// PRODUCTION_BRIDGE_SUBSCRIPTIONS', subscriptions)
flags = ['-D', 'TASK_OPERATION_OBSERVATION'] if 'var canStartTasks:' in bridge else []
errors = (source_root / 'MeoAsstMac/Model/MAAError.swift').read_text()
with tempfile.TemporaryDirectory(prefix='maa-task-operation-tests-') as tmp:
    tmp = Path(tmp)
    (tmp / 'Harness.swift').write_text(support)
    (tmp / 'MAAError.swift').write_text(errors)
    binary = tmp / 'task-operation-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-strict-concurrency=complete',
                    *flags, '-parse-as-library', str(tmp / 'MAAError.swift'), str(tmp / 'Harness.swift'),
                    str(root / 'Tests/TaskOperationTests.swift'), '-o', str(binary)], check=True)
    raise SystemExit(subprocess.run([str(binary)], timeout=45).returncode)
