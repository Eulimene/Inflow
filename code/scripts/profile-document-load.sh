#!/bin/sh
# Reproducible component benchmark, with opt-in unified logs/signposts.
set -eu
SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CODE_ROOT="$(dirname -- "${SCRIPT_DIRECTORY}")"
PROFILE_OUTPUT="${1:-${CODE_ROOT}/Build/LoadProfile}"
mkdir -p "${PROFILE_OUTPUT}"
PROFILE_OUTPUT="$(CDPATH= cd -- "${PROFILE_OUTPUT}" && pwd -P)"
APP_PATH="${PROFILE_OUTPUT}/DerivedData/Build/Products/Debug/Inflow.app"
TEST_BUNDLE="${APP_PATH}/Contents/PlugIns/InflowTests.xctest"
xcodebuild -project "${CODE_ROOT}/Inflow.xcodeproj" -scheme Inflow \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${PROFILE_OUTPUT}/DerivedData" CODE_SIGNING_ALLOWED=NO \
  build-for-testing >"${PROFILE_OUTPUT}/build.log" 2>&1
mkdir -p "${TEST_BUNDLE}/Contents/Frameworks"
cp "${APP_PATH}/Contents/MacOS/Inflow.debug.dylib" "${TEST_BUNDLE}/Contents/Frameworks/Inflow.debug.dylib"
# The benchmark has no timing thresholds: compare the same machine/configuration.
# Each process starts with cold application caches; repeat to see run-to-run noise.
for run in 1 2 3; do
  INFLOW_LOAD_BENCHMARK=1 INFLOW_PERFORMANCE_TRACE=1 OS_ACTIVITY_DT_MODE=YES \
    xcrun xctest -XCTest EditorEngineClientTests/testUnifiedDerivationReturnsOneRevisionBoundResult \
    "${TEST_BUNDLE}" >"${PROFILE_OUTPUT}/run-${run}.log" 2>&1
  rg 'LOAD_BENCHMARK|LOAD_PRESENTATION|Executed .*tests' "${PROFILE_OUTPUT}/run-${run}.log"
done
printf 'Full timing logs: %s\n' "${PROFILE_OUTPUT}"
