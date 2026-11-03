#!/bin/bash
# Capability-derivation matrix tests for CoreCapabilities.derive (P02.2).
# Compiles the production sources without launching the app or linking
# MaaCore: derivation only reads the resource tree, and its inputs come from
# FightConfiguration/SecretFrontConfiguration plus MAAClientChannel, which the
# test file stubs (the production enum lives in StartupConfiguration.swift).
# The MAAViewModel refresh wiring is not compilable in this harness --
# verify the three call sites (loadResource/reloadResources defers and
# updateChannel) manually when touching them.
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$test_dir")"
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/maa-core-capabilities-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT

xcrun swiftc -parse-as-library \
    "$repo_dir/MeoAsstMac/Core/CoreCapabilities.swift" \
    "$repo_dir/MeoAsstMac/Task Configurations/FightConfiguration.swift" \
    "$repo_dir/MeoAsstMac/Model/InventoryTarget.swift" \
    "$repo_dir/MeoAsstMac/Model/SecretFront.swift" \
    "$test_dir/CoreCapabilitiesTests.swift" \
    -module-cache-path "$test_build_dir/module-cache" \
    -o "$test_build_dir/core-capabilities-tests"
"$test_build_dir/core-capabilities-tests"
