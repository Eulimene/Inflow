#!/bin/sh

set -eu

usage() {
  echo "usage: $0 --local | --signed-archive /path/to/Inflow.xcarchive" >&2
  exit 64
}

MODE=""
SIGNED_ARCHIVE=""
case "$#:${1:-}" in
  1:--local)
    MODE="local"
    ;;
  2:--signed-archive)
    MODE="signed"
    SIGNED_ARCHIVE="$2"
    ;;
  *)
    usage
    ;;
esac

SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CODE_ROOT="$(CDPATH= cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
PROJECT_PATH="${CODE_ROOT}/Inflow.xcodeproj"
SCHEME="Inflow"

CARGO_BIN="${CARGO:-}"
if [ -z "${CARGO_BIN}" ]; then
  CARGO_BIN="$(command -v cargo || true)"
fi
if [ -z "${CARGO_BIN}" ] && [ -x "${CARGO_HOME:-${HOME}/.cargo}/bin/cargo" ]; then
  CARGO_BIN="${CARGO_HOME:-${HOME}/.cargo}/bin/cargo"
fi
if [ -z "${CARGO_BIN}" ] || [ ! -x "${CARGO_BIN}" ]; then
  echo "error: cargo is required" >&2
  exit 1
fi

VERIFICATION_ROOT="$(/usr/bin/mktemp -d -t inflow-launch-verification)"
case "${VERIFICATION_ROOT}" in
  /private/tmp/* | /private/var/* | /tmp/* | /var/*) ;;
  *)
    echo "error: refusing unexpected temporary path: ${VERIFICATION_ROOT}" >&2
    exit 1
    ;;
esac
trap '/bin/rm -rf -- "${VERIFICATION_ROOT}"' EXIT HUP INT TERM

DEBUG_RESULTS="${VERIFICATION_ROOT}/DebugTests.xcresult"
PERFORMANCE_RESULTS="${VERIFICATION_ROOT}/PerformanceTests.xcresult"

if [ "${MODE}" = "local" ]; then
  LOCAL_ARCHIVE="${INFLOW_LOCAL_ARCHIVE_PATH:-${VERIFICATION_ROOT}/Inflow.xcarchive}"
  case "${LOCAL_ARCHIVE}" in
    /*) ;;
    *)
      echo "error: INFLOW_LOCAL_ARCHIVE_PATH must be an absolute path" >&2
      exit 1
      ;;
  esac
  if [ -e "${LOCAL_ARCHIVE}" ]; then
    echo "error: refusing to replace existing local archive: ${LOCAL_ARCHIVE}" >&2
    exit 1
  fi
fi

test_summary_value() {
  result_path="$1"
  key="$2"
  summary_path="${VERIFICATION_ROOT}/$(basename "${result_path}").summary.json"
  /usr/bin/xcrun xcresulttool get test-results summary --path "${result_path}" \
    >"${summary_path}"
  /usr/bin/plutil -extract "${key}" raw "${summary_path}"
}

assert_test_results() {
  result_path="$1"
  expected_minimum="$2"
  total="$(test_summary_value "${result_path}" totalTestCount)"
  failed="$(test_summary_value "${result_path}" failedTests)"
  skipped="$(test_summary_value "${result_path}" skippedTests)"
  if [ "${total}" -lt "${expected_minimum}" ] || [ "${failed}" -ne 0 ] \
    || [ "${skipped}" -ne 0 ]
  then
    echo "error: invalid test result: total=${total}, failed=${failed}, skipped=${skipped}" >&2
    exit 1
  fi
  echo "verified XCTest result: total=${total}, failed=${failed}, skipped=${skipped}"
}

cd "${CODE_ROOT}"

"${CARGO_BIN}" fmt --manifest-path core/Cargo.toml --check
"${CARGO_BIN}" clippy --manifest-path core/Cargo.toml --locked --all-targets -- -D warnings
"${CARGO_BIN}" test --manifest-path core/Cargo.toml --locked

/usr/bin/xcodebuild -project "${PROJECT_PATH}" -list -json >/dev/null
/usr/bin/xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${VERIFICATION_ROOT}/DebugDerivedData" \
  -resultBundlePath "${DEBUG_RESULTS}" \
  CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO \
  test
assert_test_results "${DEBUG_RESULTS}" 1

/usr/bin/xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${VERIFICATION_ROOT}/AnalyzeDerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  analyze

/usr/bin/xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${VERIFICATION_ROOT}/PerformanceDerivedData" \
  -resultBundlePath "${PERFORMANCE_RESULTS}" \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES \
  -parallel-testing-enabled NO \
  -only-testing:InflowTests/MarkdownRendererTests/testMegabyteDocumentDerivesCompletePreviewWithinUpdateBudget \
  test
assert_test_results "${PERFORMANCE_RESULTS}" 1

if [ "${MODE}" = "local" ]; then
  /usr/bin/xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${VERIFICATION_ROOT}/ArchiveDerivedData" \
    -archivePath "${LOCAL_ARCHIVE}" \
    CODE_SIGNING_ALLOWED=NO \
    archive
  "${SCRIPT_DIRECTORY}/verify-release-archive.sh" --local "${LOCAL_ARCHIVE}"
else
  "${SCRIPT_DIRECTORY}/verify-release-archive.sh" "${SIGNED_ARCHIVE}"
fi

git -C "${CODE_ROOT}/.." diff --check
echo "automated launch gate passed; complete the manual and external rows in docs/launch-acceptance.md before release approval"
