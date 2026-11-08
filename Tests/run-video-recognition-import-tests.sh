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
#
# Entry-reachability contract (C13): the drop target lives in CopilotContent.swift
# (a SwiftUI view outside the compiled extraction face), so its wiring is pinned
# by fail-loudly source anchors instead — P15-1-R3 高危-1 precedent: the .movie
# dispatch branch existed but was unreachable while the drop target declared
# json-only. Any change to the entry surface must keep these anchors true.

content="$repo_dir/MeoAsstMac/Navigation/CopilotContent.swift"
anchor() {
    if ! grep -qF -- "$2" "$content"; then
        echo "FAIL: entry anchor missing ($1): $2" >&2
        exit 1
    fi
}
anchor "drop target declares json+movie" '.onDrop(of: [.json, .movie]'
anchor "file URL leg uses loadObject (loadItem returns content, not URL)" 'loadObject(ofClass: URL.self)'
anchor "movie dispatch branch intact" 'conforms(to: .movie)'
anchor "movie branch reaches recognizeVideo" 'recognizeVideo(url: url)'

xcrun swiftc -parse-as-library -module-cache-path "$test_build_dir/module-cache" \
    "$repo_dir/MeoAsstMac/Task Configurations/VideoRecognitionImport.swift" \
    "$repo_dir/MeoAsstMac/Model/CopilotFileOperations.swift" \
    "$repo_dir/MeoAsstMac/Model/MAACopilot.swift" \
    "$repo_dir/MeoAsstMac/Utils/FileManager+Atomic.swift" \
    "$repo_dir/MeoAsstMac/Utils/URL+contentType.swift" \
    "$test_dir/VideoRecognitionImportTests.swift" \
    -o "$test_build_dir/video-recognition-tests"
"$test_build_dir/video-recognition-tests"
