#!/bin/bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$test_dir")"
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/maa-minigame-params-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT

# Extraction contract: MiniGameLaunch.swift is pure Foundation (CustomTask
# params builders per Core 51dac87 CustomTask.cpp). No boundaries to stub.
# P17-[a]（快照 82 清单②）: ReclamationConfiguration.swift joins the compile
# face for the clear_store default pin; protocol/type enums are stubbed below
# (fight-config suite typealias precedent — the real ones live in Maa.swift /
# MAATaskConfiguration.swift, outside this face).

cat > "$test_build_dir/ReclamationBoundaryStubs.swift" <<'EOF'
import Foundation

typealias MAATaskConfiguration = Codable & Hashable & Sendable

enum MAATaskType: String {
    case Reclamation

    var description: String { rawValue }
}

enum MAATask {
    case reclamation(ReclamationConfiguration)
}
EOF

xcrun swiftc -parse-as-library -module-cache-path "$test_build_dir/module-cache" \
    "$repo_dir/MeoAsstMac/Task Configurations/MiniGameLaunch.swift" \
    "$repo_dir/MeoAsstMac/Task Configurations/ReclamationConfiguration.swift" \
    "$test_build_dir/ReclamationBoundaryStubs.swift" \
    "$test_dir/MiniGameLaunchTests.swift" \
    -o "$test_build_dir/minigame-params-tests"
"$test_build_dir/minigame-params-tests"
