#!/bin/sh

set -eu

usage() {
  echo "usage: $0 OUTPUT_DIRECTORY | $0 --check-os-version ACTUAL EXPECTED" >&2
  exit 64
}

die() {
  echo "error: $*" >&2
  exit 1
}

check_exact_os_version() {
  actual="$1"
  expected="$2"
  [ "${actual}" = "${expected}" ] \
    || die "expected macOS ${expected} exactly, found ${actual}"
}

if [ "$#" -eq 3 ] && [ "$1" = "--check-os-version" ]; then
  check_exact_os_version "$2" "$3"
  echo "verified exact macOS version $2"
  exit 0
fi

[ "$#" -eq 1 ] || usage

SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CODE_ROOT="$(CDPATH= cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
REPOSITORY_ROOT="$(CDPATH= cd -- "${CODE_ROOT}/.." && pwd)"
MANIFEST_PATH="${CODE_ROOT}/quality/performance-manifest.json"
OUTPUT_DIRECTORY="$1"

case "${OUTPUT_DIRECTORY}" in
  /*) ;;
  *) die "OUTPUT_DIRECTORY must be absolute" ;;
esac
[ ! -e "${OUTPUT_DIRECTORY}" ] \
  || die "refusing to replace existing output: ${OUTPUT_DIRECTORY}"
/bin/mkdir -p "${OUTPUT_DIRECTORY}"

/usr/bin/plutil -convert json -o /dev/null "${MANIFEST_PATH}" \
  || die "performance manifest is invalid JSON"

if [ -n "$(/usr/bin/git -C "${REPOSITORY_ROOT}" status --porcelain)" ]; then
  die "authoritative performance evidence requires a clean worktree"
fi

EXPECTED_MODEL="$(/usr/bin/plutil -extract authoritative_target.model_identifier raw "${MANIFEST_PATH}")"
EXPECTED_MEMORY="$(/usr/bin/plutil -extract authoritative_target.physical_memory_bytes raw "${MANIFEST_PATH}")"
EXPECTED_OS_VERSION="$(/usr/bin/plutil -extract authoritative_target.operating_system_version raw "${MANIFEST_PATH}")"
RESTART_REQUIRED="$(/usr/bin/plutil -extract measurement.measurement_session_preparation.device_restart_required raw "${MANIFEST_PATH}")"
POST_RESTART_WAIT="$(/usr/bin/plutil -extract measurement.measurement_session_preparation.post_restart_wait_seconds raw "${MANIFEST_PATH}")"
CLOSE_FOREGROUND_APPS="$(/usr/bin/plutil -extract measurement.measurement_session_preparation.close_other_user_foreground_apps raw "${MANIFEST_PATH}")"
COLD_EXITED="$(/usr/bin/plutil -extract measurement.cold_definition.inflow_exited raw "${MANIFEST_PATH}")"
COLD_IDLE="$(/usr/bin/plutil -extract measurement.cold_definition.minimum_not_running_seconds raw "${MANIFEST_PATH}")"
COLD_START="$(/usr/bin/plutil -extract measurement.cold_definition.start_event raw "${MANIFEST_PATH}")"
WARM_STATE="$(/usr/bin/plutil -extract measurement.warm_definition.inflow_state raw "${MANIFEST_PATH}")"
WARM_IDLE="$(/usr/bin/plutil -extract measurement.warm_definition.idle_seconds raw "${MANIFEST_PATH}")"
WARM_START="$(/usr/bin/plutil -extract measurement.warm_definition.start_event raw "${MANIFEST_PATH}")"
ACTUAL_MODEL="$(/usr/sbin/sysctl -n hw.model)"
ACTUAL_MEMORY="$(/usr/sbin/sysctl -n hw.memsize)"
ACTUAL_OS_VERSION="$(/usr/bin/sw_vers -productVersion)"
ACTUAL_OS_BUILD="$(/usr/bin/sw_vers -buildVersion)"
ACTUAL_ARCH="$(/usr/bin/uname -m)"

[ "${ACTUAL_ARCH}" = "arm64" ] || die "expected arm64, found ${ACTUAL_ARCH}"
[ "${ACTUAL_MODEL}" = "${EXPECTED_MODEL}" ] \
  || die "expected ${EXPECTED_MODEL}, found ${ACTUAL_MODEL}"
[ "${ACTUAL_MEMORY}" = "${EXPECTED_MEMORY}" ] \
  || die "expected ${EXPECTED_MEMORY} bytes, found ${ACTUAL_MEMORY}"
check_exact_os_version "${ACTUAL_OS_VERSION}" "${EXPECTED_OS_VERSION}"
[ "${RESTART_REQUIRED}" = "true" ] && [ "${POST_RESTART_WAIT}" = "300" ] \
  && [ "${CLOSE_FOREGROUND_APPS}" = "true" ] \
  || die "manifest measurement-session preparation does not match the product contract"
[ "${COLD_EXITED}" = "true" ] && [ "${COLD_IDLE}" = "30" ] \
  && [ "${COLD_START}" = "finder-open-request-for-benchmark-document" ] \
  || die "manifest cold-open definition does not match the product contract"
[ "${WARM_STATE}" = "one-blank-window" ] && [ "${WARM_IDLE}" = "10" ] \
  && [ "${WARM_START}" = "user-confirms-open-file" ] \
  || die "manifest warm-open definition does not match the product contract"

RESULT_PATH="${OUTPUT_DIRECTORY}/Feasibility.xcresult"
DERIVED_DATA="${OUTPUT_DIRECTORY}/DerivedData"

/usr/bin/xcodebuild \
  -project "${CODE_ROOT}/Inflow.xcodeproj" \
  -scheme Inflow \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${DERIVED_DATA}" \
  -resultBundlePath "${RESULT_PATH}" \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES \
  -parallel-testing-enabled NO \
  -only-testing:InflowTests/MarkdownRendererTests/testPerformanceManifestPinsTargetFixtureAndMeasurementProtocol \
  -only-testing:InflowTests/MarkdownRendererTests/testExactMiBTextCanTraverseTextKitRecoveryAndMountedWebKit \
  test

SUMMARY_PATH="${OUTPUT_DIRECTORY}/Feasibility-summary.json"
/usr/bin/xcrun xcresulttool get test-results summary --path "${RESULT_PATH}" \
  >"${SUMMARY_PATH}"
TOTAL="$(/usr/bin/plutil -extract totalTestCount raw "${SUMMARY_PATH}")"
FAILED="$(/usr/bin/plutil -extract failedTests raw "${SUMMARY_PATH}")"
SKIPPED="$(/usr/bin/plutil -extract skippedTests raw "${SUMMARY_PATH}")"
[ "${TOTAL}" -eq 2 ] && [ "${FAILED}" -eq 0 ] && [ "${SKIPPED}" -eq 0 ] \
  || die "feasibility tests are incomplete: total=${TOTAL}, failed=${FAILED}, skipped=${SKIPPED}"

EVIDENCE_PATH="${OUTPUT_DIRECTORY}/environment-evidence.json"
/usr/bin/plutil -create xml1 "${EVIDENCE_PATH}"
/usr/bin/plutil -insert schema_version -integer 1 "${EVIDENCE_PATH}"
/usr/bin/plutil -insert source_head -string "$(/usr/bin/git -C "${REPOSITORY_ROOT}" rev-parse HEAD)" "${EVIDENCE_PATH}"
/usr/bin/plutil -insert dirty -bool false "${EVIDENCE_PATH}"
/usr/bin/plutil -insert model_identifier -string "${ACTUAL_MODEL}" "${EVIDENCE_PATH}"
/usr/bin/plutil -insert physical_memory_bytes -integer "${ACTUAL_MEMORY}" "${EVIDENCE_PATH}"
/usr/bin/plutil -insert macos_version -string "${ACTUAL_OS_VERSION}" "${EVIDENCE_PATH}"
/usr/bin/plutil -insert macos_build -string "${ACTUAL_OS_BUILD}" "${EVIDENCE_PATH}"
/usr/bin/plutil -insert architecture -string "${ACTUAL_ARCH}" "${EVIDENCE_PATH}"
/usr/bin/plutil -insert manifest_sha256 -string "$(/usr/bin/shasum -a 256 "${MANIFEST_PATH}" | /usr/bin/awk '{ print $1 }')" "${EVIDENCE_PATH}"
/usr/bin/plutil -insert feasibility_test_count -integer "${TOTAL}" "${EVIDENCE_PATH}"
/usr/bin/plutil -insert authoritative_measurement_protocol_status -string open "${EVIDENCE_PATH}"
/usr/bin/plutil -insert required_device_restart -bool true "${EVIDENCE_PATH}"
/usr/bin/plutil -insert required_post_restart_wait_seconds -integer "${POST_RESTART_WAIT}" "${EVIDENCE_PATH}"
/usr/bin/plutil -insert required_close_other_foreground_apps -bool true "${EVIDENCE_PATH}"
/usr/bin/plutil -insert required_cold_minimum_not_running_seconds -integer "${COLD_IDLE}" "${EVIDENCE_PATH}"
/usr/bin/plutil -insert required_cold_start_event -string "${COLD_START}" "${EVIDENCE_PATH}"
/usr/bin/plutil -insert required_warm_state -string "${WARM_STATE}" "${EVIDENCE_PATH}"
/usr/bin/plutil -insert required_warm_idle_seconds -integer "${WARM_IDLE}" "${EVIDENCE_PATH}"
/usr/bin/plutil -insert required_warm_start_event -string "${WARM_START}" "${EVIDENCE_PATH}"
/usr/bin/plutil -insert exact_text_fixture_status -string passed "${EVIDENCE_PATH}"
/usr/bin/plutil -insert full_fixture_status -string open "${EVIDENCE_PATH}"
/usr/bin/plutil -insert image_fixture_status -string open "${EVIDENCE_PATH}"
/usr/bin/plutil -insert authoritative_latency_samples_complete -bool false "${EVIDENCE_PATH}"
/usr/bin/plutil -convert json "${EVIDENCE_PATH}"

echo "verified exact performance environment and exact-text chain feasibility"
echo "evidence: ${EVIDENCE_PATH}"
echo "the restart/5-minute preparation, exact cold/warm journeys, structured 20-image / 16 MiB fixture, and external latency/RSS/CPU samples remain open in ${MANIFEST_PATH}"
