#!/bin/bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$test_dir")"
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/maa-minigame-params-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT

# Extraction contract: MiniGameLaunch.swift is pure Foundation (CustomTask
# params builders per Core 51dac87 CustomTask.cpp). No boundaries to stub.

xcrun swiftc -parse-as-library -module-cache-path "$test_build_dir/module-cache" \
    "$repo_dir/MeoAsstMac/Task Configurations/MiniGameLaunch.swift" \
    "$test_dir/MiniGameLaunchTests.swift" \
    -o "$test_build_dir/minigame-params-tests"
"$test_build_dir/minigame-params-tests"
