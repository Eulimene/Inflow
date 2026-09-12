#!/bin/sh

set -eu

die() {
  echo "error: $*" >&2
  exit 1
}

SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CODE_ROOT="$(CDPATH= cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
VERIFIER="${SCRIPT_DIRECTORY}/verify-launch.sh"
RELEASE_WORKFLOW="${SCRIPT_DIRECTORY}/release-workflow.sh"
SCOPE_MANIFEST="${CODE_ROOT}/quality/personal-xctest-scope.tsv"
EXPECTED_SELECTOR_COUNT=403
EXPECTED_CURRENT_DIRECT_COUNT=297
EXPECTED_CURRENT_HOST_COUNT=13
EXPECTED_DEFERRED_COUNT=88
EXPECTED_FIXED_PERFORMANCE_COUNT=5

TEST_ROOT="$(/usr/bin/mktemp -d -t inflow-launch-scope-test)"
case "${TEST_ROOT}" in
  /private/tmp/* | /private/var/* | /tmp/* | /var/*) ;;
  *) die "refusing unexpected temporary path: ${TEST_ROOT}" ;;
esac
cleanup() {
  case "${TEST_ROOT:-}" in
    /private/tmp/* | /private/var/* | /tmp/* | /var/*)
      /bin/rm -rf -- "${TEST_ROOT}"
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

assert_line() {
  output="$1"
  expected="$2"
  printf '%s\n' "${output}" | /usr/bin/grep -Fqx -- "${expected}" \
    || die "profile description is missing: ${expected}"
}

PERSONAL_PLAN="$("${VERIFIER}" --describe-profile personal)"
assert_line "${PERSONAL_PLAN}" 'profile=personal'
assert_line "${PERSONAL_PLAN}" \
  'current_checks=rust-format,rust-clippy,rust-tests,macos-current-direct-xctest,analyze,diff-check'
assert_line "${PERSONAL_PLAN}" 'deferred_checks=none'
assert_line "${PERSONAL_PLAN}" 'archive=none'
assert_line "${PERSONAL_PLAN}" 'selector_manifest=quality/personal-xctest-scope.tsv'
assert_line "${PERSONAL_PLAN}" 'current_direct_selectors=297'
assert_line "${PERSONAL_PLAN}" 'current_host_selectors=13'
assert_line "${PERSONAL_PLAN}" 'deferred_selectors=88'
assert_line "${PERSONAL_PLAN}" 'fixed_performance_selectors=5'
assert_line "${PERSONAL_PLAN}" 'completion=manual-uat-required'

[ -f "${SCOPE_MANIFEST}" ] && [ ! -L "${SCOPE_MANIFEST}" ] \
  || die "personal XCTest scope manifest is missing or is a symlink"
/usr/bin/awk -F '\t' '
  NR == 1 {
    if ($0 != "selector\tpartition\treason") exit 10
    next
  }
  NF != 3 || $1 !~ /^[A-Za-z0-9_]+\/test[A-Za-z0-9_]+$/ || $3 == "" { exit 11 }
  $2 != "current-direct" && $2 != "current-host" \
    && $2 != "deferred" && $2 != "fixed-performance" { exit 12 }
  seen[$1]++ > 0 { exit 13 }
  END { if (NR < 2) exit 14 }
' "${SCOPE_MANIFEST}" || die "personal XCTest scope manifest is malformed"

ALL_SELECTORS="${TEST_ROOT}/all-selectors.txt"
MANIFEST_SELECTORS="${TEST_ROOT}/manifest-selectors.txt"
CURRENT_HOST_SELECTORS="${TEST_ROOT}/current-host-selectors.txt"
FIXED_PERFORMANCE_SELECTORS="${TEST_ROOT}/fixed-performance-selectors.txt"
EXPECTED_CURRENT_HOST_SELECTORS="${TEST_ROOT}/expected-current-host-selectors.txt"
EXPECTED_FIXED_PERFORMANCE_SELECTORS="${TEST_ROOT}/expected-fixed-performance-selectors.txt"

: >"${ALL_SELECTORS}"
/usr/bin/find "${CODE_ROOT}/macos/InflowTests" -type f -name '*Tests.swift' -print \
  | LC_ALL=C /usr/bin/sort \
  | while IFS= read -r test_source; do
      test_class="$(/usr/bin/basename "${test_source}" .swift)"
      /usr/bin/sed -nE \
        's/^[[:space:]]*(@[A-Za-z0-9_]+[[:space:]]+)*func[[:space:]]+(test[A-Za-z0-9_]+)[[:space:]]*\(.*/\2/p' \
        "${test_source}" \
        | while IFS= read -r test_method; do
            printf '%s/%s\n' "${test_class}" "${test_method}" >>"${ALL_SELECTORS}"
          done
    done
LC_ALL=C /usr/bin/sort -o "${ALL_SELECTORS}" "${ALL_SELECTORS}"
/usr/bin/sed '1d' "${SCOPE_MANIFEST}" | /usr/bin/cut -f 1 >"${MANIFEST_SELECTORS}"
LC_ALL=C /usr/bin/sort -c "${MANIFEST_SELECTORS}" \
  || die "personal XCTest scope manifest is not selector-sorted"
/usr/bin/cmp -s "${ALL_SELECTORS}" "${MANIFEST_SELECTORS}" \
  || die "personal XCTest scope manifest has stale or unclassified selectors"

selector_count="$(/usr/bin/wc -l <"${MANIFEST_SELECTORS}" | /usr/bin/tr -d '[:space:]')"
current_direct_count="$(/usr/bin/awk -F '\t' 'NR > 1 && $2 == "current-direct" { count++ } END { print count + 0 }' "${SCOPE_MANIFEST}")"
current_host_count="$(/usr/bin/awk -F '\t' 'NR > 1 && $2 == "current-host" { count++ } END { print count + 0 }' "${SCOPE_MANIFEST}")"
deferred_count="$(/usr/bin/awk -F '\t' 'NR > 1 && $2 == "deferred" { count++ } END { print count + 0 }' "${SCOPE_MANIFEST}")"
fixed_performance_count="$(/usr/bin/awk -F '\t' 'NR > 1 && $2 == "fixed-performance" { count++ } END { print count + 0 }' "${SCOPE_MANIFEST}")"
[ "${selector_count}" -eq "${EXPECTED_SELECTOR_COUNT}" ] \
  && [ "${current_direct_count}" -eq "${EXPECTED_CURRENT_DIRECT_COUNT}" ] \
  && [ "${current_host_count}" -eq "${EXPECTED_CURRENT_HOST_COUNT}" ] \
  && [ "${deferred_count}" -eq "${EXPECTED_DEFERRED_COUNT}" ] \
  && [ "${fixed_performance_count}" -eq "${EXPECTED_FIXED_PERFORMANCE_COUNT}" ] \
  || die "unexpected personal XCTest partition counts"

/usr/bin/awk -F '\t' 'NR > 1 && $2 == "current-host" { print $1 }' \
  "${SCOPE_MANIFEST}" >"${CURRENT_HOST_SELECTORS}"
/bin/cat >"${EXPECTED_CURRENT_HOST_SELECTORS}" <<'EOF'
DocumentRelocationTests/testFileMenuExposesSaveAsWithoutDeferredSaveCopyCommand
DocumentRelocationTests/testMenusDoNotExposePostLaunchCommands
EditorViewModeCommandsTests/testAppMenuExposesOneCommandForEachViewShortcut
FolderBrowserTests/testLaunchDocumentKeepsFileActionsInTheMacOSMenuBar
FolderBrowserTests/testLaunchFileMenuDoesNotExposeFutureFolderBrowser
HTMLExporterTests/testFileMenuHasOnePDFExportCommandAndNoHTMLEntry
InflowHelpTests/testHelpMenuHasOneAlwaysEnabledOfflineEntry
MarkdownFormatterTests/testFormatMenuExposesPersonalCommandsAndHidesDeferredCommands
MarkdownInsertionTests/testInsertMenuExposesPersonalCommandsAndHidesDeferredCommands
MarkdownSearcherTests/testAppMenuExposesOneDiscoverableCommandForEachFindShortcut
PreviewZoomCommandsTests/testLaunchMenuDoesNotExposeGrowthZoomCommands
RecentDocumentsTests/testFileMenuRoutesOpenWithoutInstallingManagedRecentDocuments
WritingModeTests/testLaunchMenuDoesNotExposeGrowthWritingModes
EOF
LC_ALL=C /usr/bin/sort -o "${EXPECTED_CURRENT_HOST_SELECTORS}" \
  "${EXPECTED_CURRENT_HOST_SELECTORS}"
/usr/bin/cmp -s "${CURRENT_HOST_SELECTORS}" "${EXPECTED_CURRENT_HOST_SELECTORS}" \
  || die "current-host selector set changed without an explicit contract update"

/usr/bin/awk -F '\t' 'NR > 1 && $2 == "fixed-performance" { print $1 }' \
  "${SCOPE_MANIFEST}" >"${FIXED_PERFORMANCE_SELECTORS}"
/bin/cat >"${EXPECTED_FIXED_PERFORMANCE_SELECTORS}" <<'EOF'
MarkdownHighlighterTests/testMegabyteHighlightApplicationIsScheduledWithoutBlockingInput
MarkdownRendererTests/testExactMiBTextCanTraverseTextKitRecoveryAndMountedWebKit
MarkdownRendererTests/testMiBDocumentDerivesCompletePreviewWithinUpdateBudget
MarkdownRendererTests/testPerformanceManifestPinsTargetFixtureAndMeasurementProtocol
MarkdownSearcherTests/testMegabyteSearchKeepsMainActorResponsive
EOF
/usr/bin/cmp -s "${FIXED_PERFORMANCE_SELECTORS}" "${EXPECTED_FIXED_PERFORMANCE_SELECTORS}" \
  || die "fixed-performance selector set changed without an explicit contract update"

for mixed_selector in \
  MarkdownFormatterTests/testFormatABILayoutAndCommandValuesMatchRustContract \
  MarkdownFormatterTests/testSessionAppliesFormatAsOneUndoUnitAndRestoresSelection \
  MarkdownFormatterTests/testFormatCommandActionsAreSceneScopedAndRespectReadOnlyState \
  MarkdownInsertionTests/testInsertionPlansApplyAsOneUndoUnit
do
  /usr/bin/awk -F '\t' -v selector="${mixed_selector}" \
    '$1 == selector && $2 == "deferred" { found = 1 } END { exit found ? 0 : 1 }' \
    "${SCOPE_MANIFEST}" \
    || die "mixed current/deferred selector must remain deferred until split: ${mixed_selector}"
done

LOCAL_RELEASE_PLAN="$("${VERIFIER}" --describe-profile deferred-release-local)"
assert_line "${LOCAL_RELEASE_PLAN}" 'profile=deferred-release-local'
assert_line "${LOCAL_RELEASE_PLAN}" \
  'deferred_checks=release-evidence-contract,fixed-performance-contract,release-archive-contract,extension-contract,fixed-performance-smoke'
assert_line "${LOCAL_RELEASE_PLAN}" 'archive=unsigned-local'
assert_line "${LOCAL_RELEASE_PLAN}" 'completion=not-personal-uat'

SIGNED_RELEASE_PLAN="$("${VERIFIER}" --describe-profile deferred-signed-archive)"
assert_line "${SIGNED_RELEASE_PLAN}" 'profile=deferred-signed-archive'
assert_line "${SIGNED_RELEASE_PLAN}" \
  'deferred_checks=release-evidence-contract,fixed-performance-contract,release-archive-contract,extension-contract,fixed-performance-smoke,release-evidence'
assert_line "${SIGNED_RELEASE_PLAN}" 'archive=provided-signed'
assert_line "${SIGNED_RELEASE_PLAN}" 'completion=not-personal-uat'

if "${VERIFIER}" --local >/dev/null 2>&1; then
  die "ambiguous legacy --local mode was accepted"
fi

RELEASE_HELP="$("${RELEASE_WORKFLOW}" help)"
printf '%s\n' "${RELEASE_HELP}" \
  | /usr/bin/grep -Fq 'deferred direct-distribution release workflow' \
  || die "release workflow does not identify itself as deferred"
printf '%s\n' "${RELEASE_HELP}" \
  | /usr/bin/grep -Fq 'part of the current personal internal milestone' \
  || die "release workflow help does not preserve the personal milestone boundary"

/usr/bin/grep -Fq \
  'exec "${VERIFY_LAUNCH}" --deferred-release-local' "${RELEASE_WORKFLOW}" \
  || die "release check does not use the explicit deferred local profile"
/usr/bin/grep -Fq \
  '"${VERIFY_LAUNCH}" --deferred-signed-archive "${archive_path}"' \
  "${RELEASE_WORKFLOW}" \
  || die "signed release paths do not use the explicit deferred profile"

echo "verified personal XCTest selectors form one explicit current/direct, current/host, deferred, and fixed-performance partition"
echo "verified personal launch gate is isolated from deferred release, extension, archive, and fixed-performance gates"
