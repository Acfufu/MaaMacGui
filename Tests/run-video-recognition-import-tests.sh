#!/bin/bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$test_dir")"
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/maa-video-recognition-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT

# Extraction contract: production VideoRecognitionImport.swift /
# CopilotFileOperations.swift / FileManager+Atomic.swift / MAACopilot.swift are
# compiled verbatim; no app-level boundary is reachable from these four files.
# The external copilot directory is redirected by the test binary itself via
# URL.externalCopilotDirectoryOverride.

xcrun swiftc -parse-as-library -module-cache-path "$test_build_dir/module-cache" \
    "$repo_dir/MeoAsstMac/Task Configurations/VideoRecognitionImport.swift" \
    "$repo_dir/MeoAsstMac/Model/CopilotFileOperations.swift" \
    "$repo_dir/MeoAsstMac/Model/MAACopilot.swift" \
    "$repo_dir/MeoAsstMac/Utils/FileManager+Atomic.swift" \
    "$repo_dir/MeoAsstMac/Utils/URL+contentType.swift" \
    "$test_dir/VideoRecognitionImportTests.swift" \
    -o "$test_build_dir/video-recognition-tests"
"$test_build_dir/video-recognition-tests"
