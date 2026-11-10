#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
swiftc -parse-as-library \
  MeoAsstMac/Utils/HGCalendar.swift \
  MeoAsstMac/Model/DailyReport/DailyReportModels.swift \
  MeoAsstMac/Model/DailyReport/DailyReportStore.swift \
  MeoAsstMac/Model/DailyReport/DailyReportCollector.swift \
  MeoAsstMac/Model/DailyReport/DailyReportMath.swift \
  Tests/DailyReportTestSupport.swift \
  Tests/DailyReportTests.swift \
  -o "$TEMP_DIR/daily-report-tests"
"$TEMP_DIR/daily-report-tests"
