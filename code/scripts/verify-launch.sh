#!/bin/sh

set -eu

usage() {
  cat >&2 <<EOF
usage:
  $0 --personal
  $0 --deferred-release-local
  $0 --deferred-signed-archive /path/to/Inflow.xcarchive
  $0 --describe-profile personal|deferred-release-local|deferred-signed-archive

--personal is the only automated gate for the current personal internal
milestone. The deferred profiles retain public-distribution, fixed-performance,
extension, archive, signing, and evidence checks without making them current
completion requirements.
EOF
  exit 64
}

describe_profile() {
  case "$1" in
    personal)
      cat <<'EOF'
profile=personal
current_checks=generated-bindings,javascript-resources,rust-format,rust-clippy,rust-tests,macos-current-direct-xctest,analyze,diff-check
deferred_checks=none
archive=none
selector_manifest=quality/personal-xctest-scope.tsv
current_direct_selectors=355
current_host_selectors=37
deferred_selectors=86
fixed_performance_selectors=5
completion=manual-uat-required
EOF
      ;;
    deferred-release-local)
      cat <<'EOF'
profile=deferred-release-local
current_checks=generated-bindings,javascript-resources,rust-format,rust-clippy,rust-tests,macos-debug-tests,analyze,diff-check
deferred_checks=release-evidence-contract,fixed-performance-contract,release-archive-contract,extension-contract,fixed-performance-smoke
archive=unsigned-local
completion=not-personal-uat
EOF
      ;;
    deferred-signed-archive)
      cat <<'EOF'
profile=deferred-signed-archive
current_checks=generated-bindings,javascript-resources,rust-format,rust-clippy,rust-tests,macos-debug-tests,analyze,diff-check
deferred_checks=release-evidence-contract,fixed-performance-contract,release-archive-contract,extension-contract,fixed-performance-smoke,release-evidence
archive=provided-signed
completion=not-personal-uat
EOF
      ;;
    *) usage ;;
  esac
}

verify_rust_build_inputs() {
  project_file="${PROJECT_PATH}/project.pbxproj"
  for rust_source in "${CODE_ROOT}"/core/src/*.rs; do
    relative_source="${rust_source#"${CODE_ROOT}/"}"
    declared_path="\$(PROJECT_DIR)/${relative_source}"
    /usr/bin/grep -Fq "\"${declared_path}\"," "${project_file}" || {
      echo "error: Rust build input is missing from Xcode: ${relative_source}" >&2
      exit 1
    }
  done
}

if [ "$#" -eq 2 ] && [ "$1" = "--describe-profile" ]; then
  describe_profile "$2"
  exit 0
fi

PROFILE=""
MODE=""
SIGNED_ARCHIVE=""
case "$#:${1:-}" in
  1:--personal)
    PROFILE="personal"
    MODE="personal"
    ;;
  1:--deferred-release-local)
    PROFILE="deferred-release"
    MODE="local"
    ;;
  2:--deferred-signed-archive)
    PROFILE="deferred-release"
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
REPOSITORY_ROOT="$(CDPATH= cd -- "${CODE_ROOT}/.." && pwd)"
PERFORMANCE_MANIFEST="${CODE_ROOT}/quality/performance-manifest.json"
PERSONAL_XCTEST_SCOPE_MANIFEST="${CODE_ROOT}/quality/personal-xctest-scope.tsv"
VERIFY_ARCHIVE="${SCRIPT_DIRECTORY}/verify-release-archive.sh"
RELEASE_WORKFLOW="${SCRIPT_DIRECTORY}/release-workflow.sh"
MINIMUM_MACOS_TEST_COUNT=300
MINIMUM_RUST_TEST_COUNT=150
PERSONAL_XCTEST_SELECTOR_COUNT=483
PERSONAL_CURRENT_DIRECT_COUNT=355
PERSONAL_CURRENT_HOST_COUNT=37
PERSONAL_DEFERRED_COUNT=86
PERSONAL_FIXED_PERFORMANCE_COUNT=5
IS_DEFERRED_RELEASE=0
if [ "${PROFILE}" = "deferred-release" ]; then
  IS_DEFERRED_RELEASE=1
fi

if [ "${PROFILE}" = "personal" ] \
  && { [ -n "${INFLOW_VERIFICATION_EVIDENCE_PATH:-}" ] \
    || [ -n "${INFLOW_LOCAL_ARCHIVE_PATH:-}" ]; }
then
  echo "error: personal verification does not accept deferred release archive or evidence outputs" >&2
  exit 1
fi

SOURCE_HEAD="$(/usr/bin/git -C "${REPOSITORY_ROOT}" rev-parse HEAD)"
SOURCE_STATUS="$(/usr/bin/git -C "${REPOSITORY_ROOT}" status --porcelain)"
if { [ "${INFLOW_REQUIRE_CLEAN_HEAD:-0}" = "1" ] || [ "${MODE}" = "signed" ]; } \
  && [ -n "${SOURCE_STATUS}" ]
then
  echo "error: retained or distributable candidates require a clean worktree" >&2
  exit 1
fi

if [ -n "${CARGO:-}" ]; then
  echo "error: launch verification does not accept a caller-supplied CARGO executable" >&2
  exit 1
fi
CARGO_BIN=""
for cargo_candidate in \
  "${HOME}/.cargo/bin/cargo" \
  /opt/homebrew/bin/cargo \
  /usr/local/bin/cargo
do
  if [ -x "${cargo_candidate}" ]; then
    CARGO_BIN="${cargo_candidate}"
    break
  fi
done
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
/bin/chmod 700 "${VERIFICATION_ROOT}"
cleanup_verification_root() {
  cleanup_root="${VERIFICATION_ROOT:-}"
  [ -n "${cleanup_root}" ] || return 0
  VERIFICATION_ROOT=""
  case "${cleanup_root}" in
    /private/tmp/* | /private/var/* | /tmp/* | /var/*)
      /bin/rm -rf -- "${cleanup_root}"
      ;;
    *)
      echo "error: refusing unexpected verification cleanup path: ${cleanup_root}" >&2
      ;;
  esac
}
trap 'cleanup_verification_root' EXIT
trap 'cleanup_verification_root; exit 129' HUP
trap 'cleanup_verification_root; exit 130' INT
trap 'cleanup_verification_root; exit 143' TERM

DEBUG_RESULTS="${VERIFICATION_ROOT}/DebugTests.xcresult"
PERFORMANCE_RESULTS="${VERIFICATION_ROOT}/PerformanceTests.xcresult"
ANALYZE_RESULTS="${VERIFICATION_ROOT}/Analyze.xcresult"
RUST_FORMAT_LOG="${VERIFICATION_ROOT}/rust-format.log"
RUST_CLIPPY_LOG="${VERIFICATION_ROOT}/rust-clippy.log"
RUST_TEST_LOG="${VERIFICATION_ROOT}/rust-tests.log"
PERSONAL_XCTEST_LOG="${VERIFICATION_ROOT}/personal-xctest.log"

sha256_file() {
  hash_value="$(/usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk 'NF == 2 { print $1; exit }')"
  echo "${hash_value}" | /usr/bin/grep -Eq '^[0-9a-f]{64}$' \
    || { echo "error: could not compute SHA-256 for $1" >&2; exit 1; }
  echo "${hash_value}"
}

tree_sha256() {
  tree_root="$1"
  tree_index="${VERIFICATION_ROOT}/tree-${RANDOM:-0}-$(/usr/bin/basename "${tree_root}").sha256"
  tree_files="${tree_index}.files"
  /usr/bin/find "${tree_root}" -type f -print >"${tree_files}" \
    || { echo "error: could not enumerate result bundle ${tree_root}" >&2; exit 1; }
  LC_ALL=C /usr/bin/sort -o "${tree_files}" "${tree_files}" \
    || { echo "error: could not sort result bundle ${tree_root}" >&2; exit 1; }
  : >"${tree_index}"
  while IFS= read -r tree_file; do
    relative_path="${tree_file#"${tree_root}"/}"
    printf '%s  %s\n' "$(sha256_file "${tree_file}")" "${relative_path}" \
      >>"${tree_index}"
  done <"${tree_files}"
  result="$(sha256_file "${tree_index}")"
  /bin/rm -f -- "${tree_index}" "${tree_files}"
  echo "${result}"
}

require_absolute_regular_file() {
  candidate_path="$1"
  label="$2"
  case "${candidate_path}" in
    /*) ;;
    *) echo "error: ${label} must be an absolute path" >&2; exit 1 ;;
  esac
  [ -f "${candidate_path}" ] && [ ! -L "${candidate_path}" ] \
    || { echo "error: ${label} must be a regular non-symlink file" >&2; exit 1; }
}

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

run_personal_macos_tests() {
  test_source_directory="${CODE_ROOT}/macos/InflowTests"
  test_bundle="${VERIFICATION_ROOT}/DebugDerivedData/Build/Products/Debug/Inflow.app/Contents/PlugIns/InflowTests.xctest"
  host_debug_library="${VERIFICATION_ROOT}/DebugDerivedData/Build/Products/Debug/Inflow.app/Contents/MacOS/Inflow.debug.dylib"
  bundle_frameworks="${test_bundle}/Contents/Frameworks"
  all_selectors="${VERIFICATION_ROOT}/all-test-selectors.txt"
  manifest_selectors="${VERIFICATION_ROOT}/manifest-test-selectors.txt"
  current_host_selectors="${VERIFICATION_ROOT}/current-host-test-selectors.txt"
  deferred_selectors="${VERIFICATION_ROOT}/deferred-test-selectors.txt"
  fixed_performance_selectors="${VERIFICATION_ROOT}/fixed-performance-test-selectors.txt"
  personal_selectors="${VERIFICATION_ROOT}/personal-test-selectors.txt"
  partition_union="${VERIFICATION_ROOT}/partition-union-test-selectors.txt"
  stale_selectors="${VERIFICATION_ROOT}/stale-manifest-test-selectors.txt"
  unclassified_selectors="${VERIFICATION_ROOT}/unclassified-source-test-selectors.txt"

  /usr/bin/xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${VERIFICATION_ROOT}/DebugDerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    -parallel-testing-enabled NO \
    build-for-testing

  [ -d "${test_bundle}" ] && [ ! -L "${test_bundle}" ] \
    || { echo "error: direct XCTest bundle is missing or is a symlink" >&2; exit 1; }
  [ -f "${host_debug_library}" ] && [ ! -L "${host_debug_library}" ] \
    || { echo "error: direct XCTest host library is missing or is a symlink" >&2; exit 1; }

  : >"${all_selectors}"
  /usr/bin/find "${test_source_directory}" -type f -name '*Tests.swift' -print \
    | LC_ALL=C /usr/bin/sort \
    | while IFS= read -r test_source; do
        test_class="$(/usr/bin/basename "${test_source}" .swift)"
        /usr/bin/sed -nE \
          's/^[[:space:]]*(@[A-Za-z0-9_]+[[:space:]]+)*func[[:space:]]+(test[A-Za-z0-9_]+)[[:space:]]*\(.*/\2/p' \
          "${test_source}" \
          | while IFS= read -r test_method; do
              printf '%s/%s\n' "${test_class}" "${test_method}" >>"${all_selectors}"
            done
      done

  LC_ALL=C /usr/bin/sort -o "${all_selectors}" "${all_selectors}"
  all_test_count="$(/usr/bin/wc -l <"${all_selectors}" | /usr/bin/tr -d '[:space:]')"
  unique_test_count="$(LC_ALL=C /usr/bin/sort -u "${all_selectors}" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')"
  [ "${all_test_count}" -gt 0 ] \
    && [ "${all_test_count}" = "${unique_test_count}" ] \
    || { echo "error: could not derive a unique direct XCTest selector set" >&2; exit 1; }

  [ -f "${PERSONAL_XCTEST_SCOPE_MANIFEST}" ] \
    && [ ! -L "${PERSONAL_XCTEST_SCOPE_MANIFEST}" ] \
    || { echo "error: personal XCTest scope manifest is missing or is a symlink" >&2; exit 1; }
  if ! /usr/bin/awk -F '\t' '
    NR == 1 {
      if ($0 != "selector\tpartition\treason") exit 10
      next
    }
    NF != 3 || $1 !~ /^[A-Za-z0-9_]+\/test[A-Za-z0-9_]+$/ || $3 == "" { exit 11 }
    $2 != "current-direct" && $2 != "current-host" \
      && $2 != "deferred" && $2 != "fixed-performance" { exit 12 }
    seen[$1]++ > 0 { exit 13 }
    END { if (NR < 2) exit 14 }
  ' "${PERSONAL_XCTEST_SCOPE_MANIFEST}"
  then
    echo "error: invalid personal XCTest scope manifest" >&2
    exit 1
  fi
  /usr/bin/sed '1d' "${PERSONAL_XCTEST_SCOPE_MANIFEST}" \
    | /usr/bin/cut -f 1 >"${manifest_selectors}"
  LC_ALL=C /usr/bin/sort -c "${manifest_selectors}" \
    || { echo "error: personal XCTest scope manifest must remain selector-sorted" >&2; exit 1; }

  LC_ALL=C /usr/bin/comm -23 "${manifest_selectors}" "${all_selectors}" \
    >"${stale_selectors}"
  LC_ALL=C /usr/bin/comm -13 "${manifest_selectors}" "${all_selectors}" \
    >"${unclassified_selectors}"
  if [ -s "${stale_selectors}" ]; then
    echo "error: stale selectors in personal XCTest scope manifest:" >&2
    /bin/cat "${stale_selectors}" >&2
    exit 1
  fi
  if [ -s "${unclassified_selectors}" ]; then
    echo "error: unclassified XCTest selectors; assign each selector explicitly:" >&2
    /bin/cat "${unclassified_selectors}" >&2
    exit 1
  fi

  /usr/bin/awk -F '\t' 'NR > 1 && $2 == "current-direct" { print $1 }' \
    "${PERSONAL_XCTEST_SCOPE_MANIFEST}" >"${personal_selectors}"
  /usr/bin/awk -F '\t' 'NR > 1 && $2 == "current-host" { print $1 }' \
    "${PERSONAL_XCTEST_SCOPE_MANIFEST}" >"${current_host_selectors}"
  /usr/bin/awk -F '\t' 'NR > 1 && $2 == "deferred" { print $1 }' \
    "${PERSONAL_XCTEST_SCOPE_MANIFEST}" >"${deferred_selectors}"
  /usr/bin/awk -F '\t' 'NR > 1 && $2 == "fixed-performance" { print $1 }' \
    "${PERSONAL_XCTEST_SCOPE_MANIFEST}" >"${fixed_performance_selectors}"

  personal_test_count="$(/usr/bin/wc -l <"${personal_selectors}" | /usr/bin/tr -d '[:space:]')"
  current_host_count="$(/usr/bin/wc -l <"${current_host_selectors}" | /usr/bin/tr -d '[:space:]')"
  deferred_test_count="$(/usr/bin/wc -l <"${deferred_selectors}" | /usr/bin/tr -d '[:space:]')"
  fixed_performance_count="$(/usr/bin/wc -l <"${fixed_performance_selectors}" | /usr/bin/tr -d '[:space:]')"
  [ "${personal_test_count}" -eq "${PERSONAL_CURRENT_DIRECT_COUNT}" ] \
    && [ "${current_host_count}" -eq "${PERSONAL_CURRENT_HOST_COUNT}" ] \
    && [ "${deferred_test_count}" -eq "${PERSONAL_DEFERRED_COUNT}" ] \
    && [ "${fixed_performance_count}" -eq "${PERSONAL_FIXED_PERFORMANCE_COUNT}" ] \
    || {
      echo "error: personal XCTest partition counts changed: current-direct=${personal_test_count}, current-host=${current_host_count}, deferred=${deferred_test_count}, fixed-performance=${fixed_performance_count}" >&2
      exit 1
    }
  /bin/cat \
    "${personal_selectors}" \
    "${current_host_selectors}" \
    "${deferred_selectors}" \
    "${fixed_performance_selectors}" \
    | LC_ALL=C /usr/bin/sort >"${partition_union}"
  partition_union_count="$(/usr/bin/wc -l <"${partition_union}" | /usr/bin/tr -d '[:space:]')"
  partition_unique_count="$(LC_ALL=C /usr/bin/sort -u "${partition_union}" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')"
  [ "${partition_union_count}" -eq "${PERSONAL_XCTEST_SELECTOR_COUNT}" ] \
    && [ "${partition_unique_count}" -eq "${PERSONAL_XCTEST_SELECTOR_COUNT}" ] \
    && /usr/bin/cmp -s "${partition_union}" "${all_selectors}" \
    || { echo "error: personal XCTest partitions do not form one disjoint complete selector set" >&2; exit 1; }

  /bin/mkdir -p "${bundle_frameworks}"
  /bin/cp -f "${host_debug_library}" "${bundle_frameworks}/Inflow.debug.dylib"
  selector_argument="$(/usr/bin/tr '\n' ',' <"${personal_selectors}" | /usr/bin/sed 's/,$//')"
  if ! /usr/bin/xcrun xctest -XCTest "${selector_argument}" "${test_bundle}" \
      >"${PERSONAL_XCTEST_LOG}" 2>&1
  then
    /bin/cat "${PERSONAL_XCTEST_LOG}" >&2
    exit 1
  fi
  /bin/cat "${PERSONAL_XCTEST_LOG}"
  /usr/bin/grep -Fq \
    "Executed ${personal_test_count} tests, with 0 failures (0 unexpected)" \
    "${PERSONAL_XCTEST_LOG}" \
    || { echo "error: direct XCTest summary does not match the selected personal test set" >&2; exit 1; }
  echo "verified personal direct XCTest result: total=${personal_test_count}, failures=0, current-host-not-run=${current_host_count}, deferred-not-run=${deferred_test_count}, fixed-performance-not-run=${fixed_performance_count}"
}

cd "${CODE_ROOT}"

verify_rust_build_inputs
"${CARGO_BIN}" run --manifest-path xtask/Cargo.toml --locked -- verify-bindings

if [ "${IS_DEFERRED_RELEASE}" -eq 1 ]; then
  "${SCRIPT_DIRECTORY}/test-release-evidence-gate.sh"
  "${SCRIPT_DIRECTORY}/test-performance-protocol-contract.sh"
  "${SCRIPT_DIRECTORY}/verify-release-archive.sh" --self-test
  "${SCRIPT_DIRECTORY}/verify-extension-contracts.sh"
fi

python3 "${SCRIPT_DIRECTORY}/verify-js-resources.py"

if ! "${CARGO_BIN}" fmt --manifest-path core/Cargo.toml --check \
  >"${RUST_FORMAT_LOG}" 2>&1
then
  /bin/cat "${RUST_FORMAT_LOG}" >&2
  exit 1
fi
/bin/cat "${RUST_FORMAT_LOG}"
if ! "${CARGO_BIN}" clippy --manifest-path core/Cargo.toml --locked --all-targets \
  -- -D warnings >"${RUST_CLIPPY_LOG}" 2>&1
then
  /bin/cat "${RUST_CLIPPY_LOG}" >&2
  exit 1
fi
/bin/cat "${RUST_CLIPPY_LOG}"
if ! "${CARGO_BIN}" test --manifest-path core/Cargo.toml --locked \
  >"${RUST_TEST_LOG}" 2>&1
then
  /bin/cat "${RUST_TEST_LOG}" >&2
  exit 1
fi
/bin/cat "${RUST_TEST_LOG}"
RUST_TEST_COUNT="$(/usr/bin/awk '
  /test result: ok\./ {
    for (field_index = 1; field_index <= NF; field_index += 1) {
      if ($(field_index + 1) == "passed;") { total += $field_index }
    }
  }
  END { print total + 0 }
' "${RUST_TEST_LOG}")"
if [ "${IS_DEFERRED_RELEASE}" -eq 1 ]; then
  [ "${RUST_TEST_COUNT}" -ge "${MINIMUM_RUST_TEST_COUNT}" ] \
    || { echo "error: deferred release Rust suite shrank below ${MINIMUM_RUST_TEST_COUNT}: ${RUST_TEST_COUNT}" >&2; exit 1; }
else
  [ "${RUST_TEST_COUNT}" -ge 1 ] \
    || { echo "error: personal milestone Rust suite executed no tests" >&2; exit 1; }
fi

/usr/bin/xcodebuild -project "${PROJECT_PATH}" -list -json >/dev/null
if [ "${IS_DEFERRED_RELEASE}" -eq 1 ]; then
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
else
  run_personal_macos_tests
fi
if [ "${IS_DEFERRED_RELEASE}" -eq 1 ]; then
  assert_test_results "${DEBUG_RESULTS}" "${MINIMUM_MACOS_TEST_COUNT}"
fi

/usr/bin/xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${VERIFICATION_ROOT}/AnalyzeDerivedData" \
  -resultBundlePath "${ANALYZE_RESULTS}" \
  CODE_SIGNING_ALLOWED=NO \
  analyze

if [ "${IS_DEFERRED_RELEASE}" -eq 1 ]; then
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
    -only-testing:InflowTests/MarkdownRendererTests/testMiBDocumentDerivesCompletePreviewWithinUpdateBudget \
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
fi

/usr/bin/git -C "${CODE_ROOT}/.." diff --check

FINAL_HEAD="$(/usr/bin/git -C "${REPOSITORY_ROOT}" rev-parse HEAD)"
FINAL_STATUS="$(/usr/bin/git -C "${REPOSITORY_ROOT}" status --porcelain)"
[ "${FINAL_HEAD}" = "${SOURCE_HEAD}" ] \
  || { echo "error: source HEAD changed while verification was running" >&2; exit 1; }
[ "${FINAL_STATUS}" = "${SOURCE_STATUS}" ] \
  || { echo "error: worktree state changed while verification was running" >&2; exit 1; }
if { [ "${INFLOW_REQUIRE_CLEAN_HEAD:-0}" = "1" ] || [ "${MODE}" = "signed" ]; } \
  && [ -n "${FINAL_STATUS}" ]
then
  echo "error: retained or distributable verification ended with a dirty worktree" >&2
  exit 1
fi

if [ "${IS_DEFERRED_RELEASE}" -eq 1 ] \
  && [ -n "${INFLOW_VERIFICATION_EVIDENCE_PATH:-}" ]
then
  EVIDENCE_PATH="${INFLOW_VERIFICATION_EVIDENCE_PATH}"
  case "${EVIDENCE_PATH}" in
    /*) ;;
    *)
      echo "error: INFLOW_VERIFICATION_EVIDENCE_PATH must be absolute" >&2
      exit 1
      ;;
  esac
  [ ! -e "${EVIDENCE_PATH}" ] || {
    echo "error: refusing to replace verification evidence: ${EVIDENCE_PATH}" >&2
    exit 1
  }
  DEBUG_TOTAL="$(test_summary_value "${DEBUG_RESULTS}" totalTestCount)"
  DEBUG_FAILED="$(test_summary_value "${DEBUG_RESULTS}" failedTests)"
  DEBUG_SKIPPED="$(test_summary_value "${DEBUG_RESULTS}" skippedTests)"
  PERFORMANCE_TOTAL="$(test_summary_value "${PERFORMANCE_RESULTS}" totalTestCount)"
  PERFORMANCE_FAILED="$(test_summary_value "${PERFORMANCE_RESULTS}" failedTests)"
  PERFORMANCE_SKIPPED="$(test_summary_value "${PERFORMANCE_RESULTS}" skippedTests)"

  if [ "${MODE}" = "signed" ]; then
    ARCHIVE_ZIP="${INFLOW_VERIFICATION_ARCHIVE_ZIP_PATH:-}"
    SIGNATURE_PATH="${INFLOW_VERIFICATION_EVIDENCE_SIGNATURE_PATH:-}"
    ARTIFACT_DIRECTORY="${INFLOW_VERIFICATION_ARTIFACT_DIRECTORY:-}"
    SIGNING_IDENTITY="${INFLOW_VERIFICATION_SIGNING_IDENTITY:-}"
    SIGNER_PIN="${INFLOW_VERIFICATION_SIGNER_SHA256:-}"
    require_absolute_regular_file "${ARCHIVE_ZIP}" "verification archive ZIP"
    case "${SIGNATURE_PATH}:${ARTIFACT_DIRECTORY}" in
      /*:/*) ;;
      *) echo "error: verification signature and artifact paths must be absolute" >&2; exit 1 ;;
    esac
    [ ! -e "${SIGNATURE_PATH}" ] && [ ! -e "${ARTIFACT_DIRECTORY}" ] \
      || { echo "error: refusing to replace verification signature or artifacts" >&2; exit 1; }
    [ -n "${SIGNING_IDENTITY}" ] \
      || { echo "error: INFLOW_VERIFICATION_SIGNING_IDENTITY is required" >&2; exit 1; }
    echo "${SIGNER_PIN}" | /usr/bin/grep -Eq '^[0-9A-Fa-f]{64}$' \
      || { echo "error: INFLOW_VERIFICATION_SIGNER_SHA256 must be a protected SHA-256 pin" >&2; exit 1; }
    SIGNER_PIN="$(echo "${SIGNER_PIN}" | /usr/bin/tr '[:upper:]' '[:lower:]')"

    APP_PATH="${SIGNED_ARCHIVE}/Products/Applications/Inflow.app"
    INFO_PATH="${APP_PATH}/Contents/Info.plist"
    BINARY_PATH="${APP_PATH}/Contents/MacOS/Inflow"
    PRIVACY_PATH="${APP_PATH}/Contents/Resources/PrivacyInfo.xcprivacy"
    for required_path in "${INFO_PATH}" "${BINARY_PATH}" "${PRIVACY_PATH}"; do
      require_absolute_regular_file "${required_path}" "signed archive artifact"
    done
    ARCHIVE_SOURCE_HEAD="$(/usr/bin/plutil -extract InflowSourceHead raw "${INFO_PATH}")"
    [ "${ARCHIVE_SOURCE_HEAD}" = "${SOURCE_HEAD}" ] \
      || { echo "error: signed archive does not bind the verified source HEAD" >&2; exit 1; }
    SIGNATURE_DETAILS="$(/usr/bin/codesign -dvv "${APP_PATH}" 2>&1)"
    APP_CDHASH="$(echo "${SIGNATURE_DETAILS}" | /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }')"
    APP_TEAM_ID="$(echo "${SIGNATURE_DETAILS}" | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
    APP_AUTHORITY="$(echo "${SIGNATURE_DETAILS}" | /usr/bin/awk -F= '$1 == "Authority" { print $2; exit }')"
    [ -n "${APP_CDHASH}" ] && [ -n "${APP_TEAM_ID}" ] && [ -n "${APP_AUTHORITY}" ] \
      || { echo "error: signed archive identity is incomplete" >&2; exit 1; }
    APP_CERTIFICATE_PREFIX="${VERIFICATION_ROOT}/app-signing-certificate"
    /usr/bin/codesign -d --extract-certificates="${APP_CERTIFICATE_PREFIX}" \
      "${APP_PATH}" >/dev/null 2>&1
    APP_CERTIFICATE_PEM="${VERIFICATION_ROOT}/app-signing-certificate.pem"
    /usr/bin/openssl x509 -inform DER -in "${APP_CERTIFICATE_PREFIX}0" \
      -out "${APP_CERTIFICATE_PEM}" >/dev/null 2>&1
    APP_SIGNER_SHA256="$(/usr/bin/openssl x509 -in "${APP_CERTIFICATE_PEM}" -outform DER \
      | /usr/bin/shasum -a 256 | /usr/bin/awk 'NF == 2 { print $1; exit }')"
    APP_SIGNER_SUBJECT="$(/usr/bin/openssl x509 -in "${APP_CERTIFICATE_PEM}" -noout \
      -subject -nameopt RFC2253 | /usr/bin/sed -E 's/^subject=[[:space:]]*//')"
    SIGNED_ENTITLEMENTS="${VERIFICATION_ROOT}/signed-entitlements.plist"
    /usr/bin/codesign -d --entitlements :- "${APP_PATH}" \
      >"${SIGNED_ENTITLEMENTS}" 2>/dev/null

    /bin/mkdir -p "${ARTIFACT_DIRECTORY}"
    /usr/bin/ditto "${DEBUG_RESULTS}" "${ARTIFACT_DIRECTORY}/DebugTests.xcresult"
    /usr/bin/ditto "${PERFORMANCE_RESULTS}" "${ARTIFACT_DIRECTORY}/PerformanceTests.xcresult"
    /usr/bin/ditto "${ANALYZE_RESULTS}" "${ARTIFACT_DIRECTORY}/Analyze.xcresult"
    /bin/cp "${RUST_FORMAT_LOG}" "${ARTIFACT_DIRECTORY}/rust-format.log"
    /bin/cp "${RUST_CLIPPY_LOG}" "${ARTIFACT_DIRECTORY}/rust-clippy.log"
    /bin/cp "${RUST_TEST_LOG}" "${ARTIFACT_DIRECTORY}/rust-tests.log"
    DEBUG_EVIDENCE_RESULTS="${ARTIFACT_DIRECTORY}/DebugTests.xcresult"
    PERFORMANCE_EVIDENCE_RESULTS="${ARTIFACT_DIRECTORY}/PerformanceTests.xcresult"
    ANALYZE_EVIDENCE_RESULTS="${ARTIFACT_DIRECTORY}/Analyze.xcresult"
    RUST_FORMAT_EVIDENCE_LOG="${ARTIFACT_DIRECTORY}/rust-format.log"
    RUST_CLIPPY_EVIDENCE_LOG="${ARTIFACT_DIRECTORY}/rust-clippy.log"
    RUST_TEST_EVIDENCE_LOG="${ARTIFACT_DIRECTORY}/rust-tests.log"
  else
    DEBUG_EVIDENCE_RESULTS="${DEBUG_RESULTS}"
    PERFORMANCE_EVIDENCE_RESULTS="${PERFORMANCE_RESULTS}"
    ANALYZE_EVIDENCE_RESULTS="${ANALYZE_RESULTS}"
    RUST_FORMAT_EVIDENCE_LOG="${RUST_FORMAT_LOG}"
    RUST_CLIPPY_EVIDENCE_LOG="${RUST_CLIPPY_LOG}"
    RUST_TEST_EVIDENCE_LOG="${RUST_TEST_LOG}"
  fi

  /usr/bin/plutil -create xml1 "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert schema_version -integer 1 "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert evidence_kind -string inflow-launch-verification "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert status -string passed "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert source_head -string "${SOURCE_HEAD}" "${EVIDENCE_PATH}"
  if [ -n "${SOURCE_STATUS}" ]; then
    /usr/bin/plutil -insert dirty -bool true "${EVIDENCE_PATH}"
  else
    /usr/bin/plutil -insert dirty -bool false "${EVIDENCE_PATH}"
  fi
  /usr/bin/plutil -insert mode -string "${MODE}" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert created_at_utc -string "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert xcode -string "$(/usr/bin/xcodebuild -version | /usr/bin/tr '\n' ';')" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert rust -string "$("${CARGO_BIN}" --version)" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert rust_format_passed -bool true "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert rust_clippy_passed -bool true "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert rust_tests_passed -bool true "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert rust_test_count -integer "${RUST_TEST_COUNT}" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert rust_format_log_sha256 -string "$(sha256_file "${RUST_FORMAT_EVIDENCE_LOG}")" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert rust_clippy_log_sha256 -string "$(sha256_file "${RUST_CLIPPY_EVIDENCE_LOG}")" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert rust_test_log_sha256 -string "$(sha256_file "${RUST_TEST_EVIDENCE_LOG}")" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert macos_test_count -integer "${DEBUG_TOTAL}" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert macos_failed_test_count -integer "${DEBUG_FAILED}" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert macos_skipped_test_count -integer "${DEBUG_SKIPPED}" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert macos_tests_passed -bool true "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert debug_xcresult_sha256 -string "$(tree_sha256 "${DEBUG_EVIDENCE_RESULTS}")" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert analyze_passed -bool true "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert analyze_xcresult_sha256 -string "$(tree_sha256 "${ANALYZE_EVIDENCE_RESULTS}")" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert repository_performance_smoke_passed -bool true "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert repository_performance_test_count -integer "${PERFORMANCE_TOTAL}" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert repository_performance_failed_test_count -integer "${PERFORMANCE_FAILED}" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert repository_performance_skipped_test_count -integer "${PERFORMANCE_SKIPPED}" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert performance_xcresult_sha256 -string "$(tree_sha256 "${PERFORMANCE_EVIDENCE_RESULTS}")" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert performance_manifest_sha256 -string "$(/usr/bin/shasum -a 256 "${PERFORMANCE_MANIFEST}" | /usr/bin/awk '{ print $1 }')" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert authoritative_target_performance_complete -bool false "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert archive_verified -bool true "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert verify_launch_script_sha256 -string "$(sha256_file "$0")" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert verify_archive_script_sha256 -string "$(sha256_file "${VERIFY_ARCHIVE}")" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert release_workflow_script_sha256 -string "$(sha256_file "${RELEASE_WORKFLOW}")" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert project_file_sha256 -string "$(sha256_file "${PROJECT_PATH}/project.pbxproj")" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert cargo_lock_sha256 -string "$(sha256_file "${CODE_ROOT}/core/Cargo.lock")" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert cargo_toml_sha256 -string "$(sha256_file "${CODE_ROOT}/core/Cargo.toml")" "${EVIDENCE_PATH}"
  /usr/bin/plutil -insert rust_toolchain_sha256 -string "$(sha256_file "${CODE_ROOT}/rust-toolchain.toml")" "${EVIDENCE_PATH}"
  if [ "${MODE}" = "signed" ]; then
    /usr/bin/plutil -insert archive_zip_sha256 -string "$(sha256_file "${ARCHIVE_ZIP}")" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert app_source_head -string "${ARCHIVE_SOURCE_HEAD}" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert app_bundle_id -string "$(/usr/bin/plutil -extract CFBundleIdentifier raw "${INFO_PATH}")" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert app_marketing_version -string "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "${INFO_PATH}")" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert app_build_version -string "$(/usr/bin/plutil -extract CFBundleVersion raw "${INFO_PATH}")" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert app_release_profile -string "$(/usr/bin/plutil -extract InflowReleaseProfile raw "${INFO_PATH}")" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert manual_update_url_sha256 -string "$(printf '%s' "$(/usr/bin/plutil -extract InflowManualUpdateURL raw "${INFO_PATH}")" | /usr/bin/shasum -a 256 | /usr/bin/awk 'NF == 2 { print $1; exit }')" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert app_info_plist_sha256 -string "$(sha256_file "${INFO_PATH}")" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert app_binary_sha256 -string "$(sha256_file "${BINARY_PATH}")" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert app_cdhash -string "${APP_CDHASH}" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert app_team_id -string "${APP_TEAM_ID}" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert app_signing_authority -string "${APP_AUTHORITY}" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert app_signing_certificate_sha256 -string "${APP_SIGNER_SHA256}" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert app_signing_certificate_subject_rfc2253 -string "${APP_SIGNER_SUBJECT}" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert app_entitlements_sha256 -string "$(sha256_file "${SIGNED_ENTITLEMENTS}")" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert app_privacy_manifest_sha256 -string "$(sha256_file "${PRIVACY_PATH}")" "${EVIDENCE_PATH}"
    /usr/bin/plutil -insert verification_signer_sha256 -string "${SIGNER_PIN}" "${EVIDENCE_PATH}"
  fi
  /usr/bin/plutil -convert json "${EVIDENCE_PATH}"
  if [ "${MODE}" = "signed" ]; then
    /usr/bin/security cms -S -T -G -H SHA256 -u 6 -N "${SIGNING_IDENTITY}" \
      -i "${EVIDENCE_PATH}" -o "${SIGNATURE_PATH}" \
      || { echo "error: failed to sign verification evidence" >&2; exit 1; }

    RECEIPT_TRUST_ROOT="${VERIFICATION_ROOT}/receipt-trust"
    /bin/mkdir "${RECEIPT_TRUST_ROOT}"
    /bin/chmod 700 "${RECEIPT_TRUST_ROOT}"
    TRUSTED_EVIDENCE_PATH="${RECEIPT_TRUST_ROOT}/verification-evidence.json"
    TRUSTED_SIGNATURE_PATH="${RECEIPT_TRUST_ROOT}/verification-evidence.json.cms"
    RECEIPT_CERTIFICATE="${RECEIPT_TRUST_ROOT}/signer.pem"
    require_absolute_regular_file "${EVIDENCE_PATH}" "verification evidence"
    require_absolute_regular_file "${SIGNATURE_PATH}" "verification evidence CMS"
    /bin/cp -p "${EVIDENCE_PATH}" "${TRUSTED_EVIDENCE_PATH}" \
      || { echo "error: could not snapshot verification evidence" >&2; exit 1; }
    /bin/cp -p "${SIGNATURE_PATH}" "${TRUSTED_SIGNATURE_PATH}" \
      || { echo "error: could not snapshot verification evidence CMS" >&2; exit 1; }
    require_absolute_regular_file "${TRUSTED_EVIDENCE_PATH}" "trusted verification evidence snapshot"
    require_absolute_regular_file "${TRUSTED_SIGNATURE_PATH}" "trusted verification CMS snapshot"
    /bin/chmod 400 "${TRUSTED_EVIDENCE_PATH}" "${TRUSTED_SIGNATURE_PATH}"
    /usr/bin/openssl cms -verify -binary -inform DER -noverify \
      -in "${TRUSTED_SIGNATURE_PATH}" -content "${TRUSTED_EVIDENCE_PATH}" \
      -signer "${RECEIPT_CERTIFICATE}" -out /dev/null >/dev/null 2>&1 \
      || { echo "error: verification evidence CMS content is invalid" >&2; exit 1; }
    RECEIPT_SIGNER_COUNT="$({
      /usr/bin/grep -c '^-----BEGIN CERTIFICATE-----$' "${RECEIPT_CERTIFICATE}" || true
    })"
    [ "${RECEIPT_SIGNER_COUNT}" = "1" ] \
      || { echo "error: verification evidence CMS must contain exactly one signer" >&2; exit 1; }
    /bin/chmod 400 "${RECEIPT_CERTIFICATE}"
    /usr/bin/security cms -D -u 6 -c "${TRUSTED_EVIDENCE_PATH}" \
      -i "${TRUSTED_SIGNATURE_PATH}" -o /dev/null \
      || { echo "error: verification evidence signer is not trusted" >&2; exit 1; }
    /usr/bin/security verify-cert -c "${RECEIPT_CERTIFICATE}" \
      -p basic -L -q >/dev/null 2>&1 \
      || { echo "error: verification evidence signer certificate chain is not trusted" >&2; exit 1; }
    ACTUAL_SIGNER_PIN="$(/usr/bin/openssl x509 -in "${RECEIPT_CERTIFICATE}" -outform DER \
      | /usr/bin/shasum -a 256 | /usr/bin/awk 'NF == 2 { print $1; exit }')"
    [ "${ACTUAL_SIGNER_PIN}" = "${SIGNER_PIN}" ] \
      || { echo "error: verification evidence signer does not match protected pin" >&2; exit 1; }
    echo "verification evidence signature: ${SIGNATURE_PATH}"
    echo "verification artifacts: ${ARTIFACT_DIRECTORY}"
  fi
  echo "verification evidence: ${EVIDENCE_PATH}"
fi
if [ "${PROFILE}" = "personal" ]; then
  echo "personal milestone automation passed; UAT-PERSONAL-01 through 10 still require product-owner execution and sign-off"
else
  echo "deferred release automation passed; this result is not a personal milestone UAT decision or public release approval"
fi
