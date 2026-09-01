#!/bin/sh

set -eu

die() {
  echo "error: $*" >&2
  exit 1
}

SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CODE_ROOT="$(CDPATH= cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
REPOSITORY_ROOT="$(CDPATH= cd -- "${CODE_ROOT}/.." && pwd)"
WORKFLOW="${SCRIPT_DIRECTORY}/release-workflow.sh"
MANIFEST="${CODE_ROOT}/quality/performance-manifest.json"
TEST_ROOT="$(/usr/bin/mktemp -d -t inflow-release-evidence-test)"
case "${TEST_ROOT}" in
  /private/tmp/* | /private/var/* | /tmp/* | /var/*) ;;
  *) die "refusing unexpected test path: ${TEST_ROOT}" ;;
esac
trap '/bin/rm -rf -- "${TEST_ROOT}"' EXIT HUP INT TERM

SOURCE_HEAD="$(/usr/bin/git -C "${REPOSITORY_ROOT}" rev-parse HEAD)"
MANIFEST_SHA256="$(/usr/bin/shasum -a 256 "${MANIFEST}" | /usr/bin/awk '{ print $1 }')"
TEXT_SHA256="$(/usr/bin/plutil -extract fixture.sha256 raw "${MANIFEST}")"
PERFORMANCE_JSON="${TEST_ROOT}/performance.json"
PRODUCT_JSON="${TEST_ROOT}/product.json"

write_performance_receipt() {
  output="$1"
  measured_runs="$2"
  /usr/bin/plutil -create xml1 "${output}"
  /usr/bin/plutil -insert schema_version -integer 1 "${output}"
  /usr/bin/plutil -insert status -string passed "${output}"
  /usr/bin/plutil -insert source_head -string "${SOURCE_HEAD}" "${output}"
  /usr/bin/plutil -insert dirty -bool false "${output}"
  /usr/bin/plutil -insert manifest_sha256 -string "${MANIFEST_SHA256}" "${output}"
  /usr/bin/plutil -insert model_identifier -string MacBookAir10,1 "${output}"
  /usr/bin/plutil -insert physical_memory_bytes -integer 8589934592 "${output}"
  /usr/bin/plutil -insert macos_version -string 14.0 "${output}"
  /usr/bin/plutil -insert macos_build -string 23Z999 "${output}"
  /usr/bin/plutil -insert architecture -string arm64 "${output}"
  /usr/bin/plutil -insert text_fixture_sha256 -string "${TEXT_SHA256}" "${output}"
  /usr/bin/plutil -insert text_fixture_bytes -integer 1048576 "${output}"
  /usr/bin/plutil -insert text_fixture_lines -integer 10000 "${output}"
  /usr/bin/plutil -insert structure_fixture_sha256 -string "$(printf '1%.0s' $(seq 1 64))" "${output}"
  /usr/bin/plutil -insert image_count -integer 20 "${output}"
  /usr/bin/plutil -insert image_total_bytes -integer 16777216 "${output}"
  /usr/bin/plutil -insert image_corpus_sha256 -string "$(printf '2%.0s' $(seq 1 64))" "${output}"
  /usr/bin/plutil -insert full_fixture_sha256 -string "$(printf '3%.0s' $(seq 1 64))" "${output}"
  /usr/bin/plutil -insert full_fixture_status -string passed "${output}"
  /usr/bin/plutil -insert warmup_runs -integer 3 "${output}"
  /usr/bin/plutil -insert measured_runs -integer "${measured_runs}" "${output}"
  /usr/bin/plutil -insert device_restarted -bool true "${output}"
  /usr/bin/plutil -insert post_restart_wait_seconds -integer 300 "${output}"
  /usr/bin/plutil -insert other_foreground_apps_closed -bool true "${output}"
  /usr/bin/plutil -insert cold_inflow_exited -bool true "${output}"
  /usr/bin/plutil -insert cold_minimum_not_running_seconds -integer 30 "${output}"
  /usr/bin/plutil -insert cold_start_event -string finder-open-request-for-benchmark-document "${output}"
  /usr/bin/plutil -insert warm_inflow_state -string one-blank-window "${output}"
  /usr/bin/plutil -insert warm_idle_seconds -integer 10 "${output}"
  /usr/bin/plutil -insert warm_start_event -string user-confirms-open-file "${output}"
  /usr/bin/plutil -insert latency_sample_count -integer 30 "${output}"
  /usr/bin/plutil -insert resource_sample_window_seconds -integer 30 "${output}"
  /usr/bin/plutil -insert continuous_input_duration_seconds -integer 60 "${output}"
  /usr/bin/plutil -insert statistics_complete -bool true "${output}"
  /usr/bin/plutil -insert process_tree_complete -bool true "${output}"
  /usr/bin/plutil -insert preview_update_p95_milliseconds -float 250 "${output}"
  /usr/bin/plutil -insert view_switch_maximum_milliseconds -float 120 "${output}"
  /usr/bin/plutil -insert input_pause_p95_milliseconds -float 40 "${output}"
  /usr/bin/plutil -insert input_pause_maximum_milliseconds -float 80 "${output}"
  /usr/bin/plutil -insert blank_window_median_milliseconds -float 1200 "${output}"
  /usr/bin/plutil -insert blank_window_maximum_milliseconds -float 1800 "${output}"
  /usr/bin/plutil -insert warm_open_median_milliseconds -float 1200 "${output}"
  /usr/bin/plutil -insert warm_open_p95_milliseconds -float 1800 "${output}"
  /usr/bin/plutil -insert cold_open_median_milliseconds -float 2200 "${output}"
  /usr/bin/plutil -insert cold_open_maximum_milliseconds -float 2800 "${output}"
  /usr/bin/plutil -insert aggregate_rss_peak_bytes -integer 400000000 "${output}"
  /usr/bin/plutil -insert aggregate_cpu_window_percent -float 150 "${output}"
  /usr/bin/plutil -insert raw_samples_sha256 -string "$(printf '4%.0s' $(seq 1 64))" "${output}"
  /usr/bin/plutil -insert statistics_sha256 -string "$(printf '5%.0s' $(seq 1 64))" "${output}"
  /usr/bin/plutil -insert process_tree_sha256 -string "$(printf '6%.0s' $(seq 1 64))" "${output}"
  /usr/bin/plutil -insert authoritative_latency_samples_complete -bool true "${output}"
  /usr/bin/plutil -convert json "${output}"
}

write_product_receipt() {
  output="$1"
  status="$2"
  /usr/bin/plutil -create xml1 "${output}"
  /usr/bin/plutil -insert schema_version -integer 1 "${output}"
  /usr/bin/plutil -insert status -string "${status}" "${output}"
  /usr/bin/plutil -insert baseline_id -string TEST-BASELINE "${output}"
  /usr/bin/plutil -insert source_head -string "${SOURCE_HEAD}" "${output}"
  /usr/bin/plutil -insert document_set_sha256 -string "$(printf '7%.0s' $(seq 1 64))" "${output}"
  /usr/bin/plutil -insert approver_id -string test-product-owner "${output}"
  /usr/bin/plutil -insert approved_at_utc -string 2026-08-30T00:00:00Z "${output}"
  /usr/bin/plutil -convert json "${output}"
}

make_signer() {
  label="$1"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj "/CN=Inflow ${label} test signer" \
    -keyout "${TEST_ROOT}/${label}.key" -out "${TEST_ROOT}/${label}.pem" \
    >/dev/null 2>&1
}

make_release_signer() {
  label="$1"
  team_id="$2"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj "/CN=Inflow ${label} release signer/OU=${team_id}/O=Inflow Test" \
    -keyout "${TEST_ROOT}/${label}.key" -out "${TEST_ROOT}/${label}.pem" \
    >/dev/null 2>&1
}

sign_receipt() {
  input="$1"
  label="$2"
  output="$3"
  /usr/bin/openssl cms -sign -binary -outform DER -md sha256 -nosmimecap \
    -in "${input}" -signer "${TEST_ROOT}/${label}.pem" \
    -inkey "${TEST_ROOT}/${label}.key" -out "${output}"
}

certificate_sha256() {
  /usr/bin/openssl x509 -in "$1" -outform DER \
    | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
}

certificate_subject_rfc2253() {
  /usr/bin/openssl x509 -in "$1" -noout -subject -nameopt RFC2253 \
    | /usr/bin/sed -E 's/^subject=[[:space:]]*//'
}

write_release_manifest() {
  output="$1"
  sequence="$2"
  team_id="$3"
  bundle_id="$4"
  signer_certificate="$5"
  /usr/bin/plutil -create xml1 "${output}"
  /usr/bin/plutil -insert schema_version -integer 2 "${output}"
  /usr/bin/plutil -insert release_sequence -integer "${sequence}" "${output}"
  /usr/bin/plutil -insert channel -string stable-direct "${output}"
  /usr/bin/plutil -insert distribution_profile -string developer-id-notarized-zip "${output}"
  /usr/bin/plutil -insert bundle_id -string "${bundle_id}" "${output}"
  /usr/bin/plutil -insert team_id -string "${team_id}" "${output}"
  /usr/bin/plutil -insert signing_certificate_sha256 -string \
    "$(certificate_sha256 "${signer_certificate}")" "${output}"
  /usr/bin/plutil -insert signing_certificate_subject_rfc2253 -string \
    "$(certificate_subject_rfc2253 "${signer_certificate}")" "${output}"
  /usr/bin/plutil -convert json "${output}"
}

sha256_file() {
  /usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk 'NF == 2 { print $1; exit }'
}

hash_character() {
  character="$1"
  /usr/bin/awk -v character="${character}" 'BEGIN { for (i = 0; i < 64; i += 1) printf "%s", character }'
}

write_expected_app_fields() {
  output="$1"
  /usr/bin/plutil -create xml1 "${output}"
  /usr/bin/plutil -insert app_source_head -string "${SOURCE_HEAD}" "${output}"
  /usr/bin/plutil -insert app_bundle_id -string com.inflow.desktop "${output}"
  /usr/bin/plutil -insert app_marketing_version -string 0.1.0 "${output}"
  /usr/bin/plutil -insert app_build_version -string 1 "${output}"
  /usr/bin/plutil -insert app_release_profile -string signed-preview "${output}"
  /usr/bin/plutil -insert manual_update_url_sha256 -string "$(hash_character a)" "${output}"
  /usr/bin/plutil -insert app_info_plist_sha256 -string "$(hash_character b)" "${output}"
  /usr/bin/plutil -insert app_binary_sha256 -string "$(hash_character c)" "${output}"
  /usr/bin/plutil -insert app_cdhash -string 0123456789abcdef0123456789abcdef01234567 "${output}"
  /usr/bin/plutil -insert app_team_id -string TESTTEAM1 "${output}"
  /usr/bin/plutil -insert app_signing_authority -string \
    "Developer ID Application: Inflow Test (TESTTEAM1)" "${output}"
  /usr/bin/plutil -insert app_signing_certificate_sha256 -string "$(hash_character d)" "${output}"
  /usr/bin/plutil -insert app_signing_certificate_subject_rfc2253 -string \
    "CN=Inflow Test,OU=TESTTEAM1" "${output}"
  /usr/bin/plutil -insert app_entitlements_sha256 -string "$(hash_character e)" "${output}"
  /usr/bin/plutil -insert app_privacy_manifest_sha256 -string "$(hash_character f)" "${output}"
  /usr/bin/plutil -convert json "${output}"
}

write_verification_receipt() {
  output="$1"
  signer_pin="$2"
  archive_zip="$3"
  /usr/bin/plutil -create xml1 "${output}"
  /usr/bin/plutil -insert schema_version -integer 1 "${output}"
  /usr/bin/plutil -insert evidence_kind -string inflow-launch-verification "${output}"
  /usr/bin/plutil -insert status -string passed "${output}"
  /usr/bin/plutil -insert source_head -string "${SOURCE_HEAD}" "${output}"
  /usr/bin/plutil -insert dirty -bool false "${output}"
  /usr/bin/plutil -insert mode -string signed "${output}"
  /usr/bin/plutil -insert created_at_utc -string 2026-08-30T00:00:00Z "${output}"
  /usr/bin/plutil -insert xcode -string "Xcode test" "${output}"
  /usr/bin/plutil -insert rust -string "cargo test" "${output}"
  /usr/bin/plutil -insert rust_format_passed -bool true "${output}"
  /usr/bin/plutil -insert rust_clippy_passed -bool true "${output}"
  /usr/bin/plutil -insert rust_tests_passed -bool true "${output}"
  /usr/bin/plutil -insert rust_test_count -integer 150 "${output}"
  /usr/bin/plutil -insert rust_format_log_sha256 -string "$(hash_character 1)" "${output}"
  /usr/bin/plutil -insert rust_clippy_log_sha256 -string "$(hash_character 2)" "${output}"
  /usr/bin/plutil -insert rust_test_log_sha256 -string "$(hash_character 3)" "${output}"
  /usr/bin/plutil -insert macos_tests_passed -bool true "${output}"
  /usr/bin/plutil -insert macos_test_count -integer 300 "${output}"
  /usr/bin/plutil -insert macos_failed_test_count -integer 0 "${output}"
  /usr/bin/plutil -insert macos_skipped_test_count -integer 0 "${output}"
  /usr/bin/plutil -insert debug_xcresult_sha256 -string "$(hash_character 4)" "${output}"
  /usr/bin/plutil -insert analyze_passed -bool true "${output}"
  /usr/bin/plutil -insert analyze_xcresult_sha256 -string "$(hash_character 5)" "${output}"
  /usr/bin/plutil -insert repository_performance_smoke_passed -bool true "${output}"
  /usr/bin/plutil -insert repository_performance_test_count -integer 1 "${output}"
  /usr/bin/plutil -insert repository_performance_failed_test_count -integer 0 "${output}"
  /usr/bin/plutil -insert repository_performance_skipped_test_count -integer 0 "${output}"
  /usr/bin/plutil -insert performance_xcresult_sha256 -string "$(hash_character 6)" "${output}"
  /usr/bin/plutil -insert performance_manifest_sha256 -string \
    "$(sha256_file "${MANIFEST}")" "${output}"
  /usr/bin/plutil -insert authoritative_target_performance_complete -bool false "${output}"
  /usr/bin/plutil -insert archive_verified -bool true "${output}"
  /usr/bin/plutil -insert archive_zip_sha256 -string "$(sha256_file "${archive_zip}")" "${output}"
  /usr/bin/plutil -insert verify_launch_script_sha256 -string \
    "$(sha256_file "${SCRIPT_DIRECTORY}/verify-launch.sh")" "${output}"
  /usr/bin/plutil -insert verify_archive_script_sha256 -string \
    "$(sha256_file "${SCRIPT_DIRECTORY}/verify-release-archive.sh")" "${output}"
  /usr/bin/plutil -insert release_workflow_script_sha256 -string \
    "$(sha256_file "${WORKFLOW}")" "${output}"
  /usr/bin/plutil -insert project_file_sha256 -string \
    "$(sha256_file "${CODE_ROOT}/Inflow.xcodeproj/project.pbxproj")" "${output}"
  /usr/bin/plutil -insert cargo_lock_sha256 -string \
    "$(sha256_file "${CODE_ROOT}/core/Cargo.lock")" "${output}"
  /usr/bin/plutil -insert cargo_toml_sha256 -string \
    "$(sha256_file "${CODE_ROOT}/core/Cargo.toml")" "${output}"
  /usr/bin/plutil -insert rust_toolchain_sha256 -string \
    "$(sha256_file "${CODE_ROOT}/rust-toolchain.toml")" "${output}"
  /usr/bin/plutil -insert app_source_head -string "${SOURCE_HEAD}" "${output}"
  /usr/bin/plutil -insert app_bundle_id -string com.inflow.desktop "${output}"
  /usr/bin/plutil -insert app_marketing_version -string 0.1.0 "${output}"
  /usr/bin/plutil -insert app_build_version -string 1 "${output}"
  /usr/bin/plutil -insert app_release_profile -string signed-preview "${output}"
  /usr/bin/plutil -insert manual_update_url_sha256 -string "$(hash_character a)" "${output}"
  /usr/bin/plutil -insert app_info_plist_sha256 -string "$(hash_character b)" "${output}"
  /usr/bin/plutil -insert app_binary_sha256 -string "$(hash_character c)" "${output}"
  /usr/bin/plutil -insert app_cdhash -string 0123456789abcdef0123456789abcdef01234567 "${output}"
  /usr/bin/plutil -insert app_team_id -string TESTTEAM1 "${output}"
  /usr/bin/plutil -insert app_signing_authority -string \
    "Developer ID Application: Inflow Test (TESTTEAM1)" "${output}"
  /usr/bin/plutil -insert app_signing_certificate_sha256 -string "$(hash_character d)" "${output}"
  /usr/bin/plutil -insert app_signing_certificate_subject_rfc2253 -string \
    "CN=Inflow Test,OU=TESTTEAM1" "${output}"
  /usr/bin/plutil -insert app_entitlements_sha256 -string "$(hash_character e)" "${output}"
  /usr/bin/plutil -insert app_privacy_manifest_sha256 -string "$(hash_character f)" "${output}"
  /usr/bin/plutil -insert verification_signer_sha256 -string "${signer_pin}" "${output}"
  /usr/bin/plutil -convert json "${output}"
}

write_performance_receipt "${PERFORMANCE_JSON}" 30
write_product_receipt "${PRODUCT_JSON}" approved
make_signer performance
make_signer product
sign_receipt "${PERFORMANCE_JSON}" performance "${PERFORMANCE_JSON}.cms"
sign_receipt "${PRODUCT_JSON}" product "${PRODUCT_JSON}.cms"
PERFORMANCE_PIN="$(certificate_sha256 "${TEST_ROOT}/performance.pem")"
PRODUCT_PIN="$(certificate_sha256 "${TEST_ROOT}/product.pem")"

make_signer verification
VERIFICATION_PIN="$(certificate_sha256 "${TEST_ROOT}/verification.pem")"
VERIFICATION_ARCHIVE_ROOT="${TEST_ROOT}/verification-archive-payload"
VERIFICATION_ARCHIVE_ZIP="${TEST_ROOT}/verification-archive.zip"
/bin/mkdir -p "${VERIFICATION_ARCHIVE_ROOT}"
printf '%s\n' verified >"${VERIFICATION_ARCHIVE_ROOT}/evidence.txt"
/usr/bin/ditto -c -k --keepParent \
  "${VERIFICATION_ARCHIVE_ROOT}" "${VERIFICATION_ARCHIVE_ZIP}"
VERIFICATION_JSON="${TEST_ROOT}/verification.json"
VERIFICATION_APP_FIELDS="${TEST_ROOT}/verification-app-fields.json"
write_verification_receipt \
  "${VERIFICATION_JSON}" "${VERIFICATION_PIN}" "${VERIFICATION_ARCHIVE_ZIP}"
write_expected_app_fields "${VERIFICATION_APP_FIELDS}"
sign_receipt "${VERIFICATION_JSON}" verification "${VERIFICATION_JSON}.cms"
INFLOW_VERIFICATION_SIGNER_SHA256="${VERIFICATION_PIN}" \
  "${WORKFLOW}" verify-verification-receipt \
  "${VERIFICATION_JSON}" "${VERIFICATION_JSON}.cms" "${SOURCE_HEAD}" \
  "${VERIFICATION_ARCHIVE_ZIP}" "${VERIFICATION_APP_FIELDS}" >/dev/null

if INFLOW_VERIFICATION_SIGNER_SHA256="${VERIFICATION_PIN}" \
  "${WORKFLOW}" verify-trusted-verification-receipt \
  "${VERIFICATION_JSON}" "${VERIFICATION_JSON}.cms" "${SOURCE_HEAD}" \
  "${VERIFICATION_ARCHIVE_ZIP}" "${VERIFICATION_APP_FIELDS}" >/dev/null 2>&1
then
  die "self-signed verification receipt satisfied the production trust policy"
fi

make_signer verification-second
DUAL_SIGNER_CMS="${TEST_ROOT}/verification-dual-signer.cms"
/usr/bin/openssl cms -sign -binary -outform DER -md sha256 -nosmimecap \
  -in "${VERIFICATION_JSON}" \
  -signer "${TEST_ROOT}/verification.pem" \
  -inkey "${TEST_ROOT}/verification.key" \
  -signer "${TEST_ROOT}/verification-second.pem" \
  -inkey "${TEST_ROOT}/verification-second.key" \
  -out "${DUAL_SIGNER_CMS}"
DUAL_SIGNER_ERROR="${TEST_ROOT}/verification-dual-signer.error"
if INFLOW_VERIFICATION_SIGNER_SHA256="${VERIFICATION_PIN}" \
  "${WORKFLOW}" verify-trusted-verification-receipt \
  "${VERIFICATION_JSON}" "${DUAL_SIGNER_CMS}" "${SOURCE_HEAD}" \
  "${VERIFICATION_ARCHIVE_ZIP}" "${VERIFICATION_APP_FIELDS}" \
  >"${DUAL_SIGNER_ERROR}" 2>&1
then
  die "dual-signer verification receipt satisfied the production trust policy"
fi
/usr/bin/grep -Fq \
  "repository verification CMS must contain exactly one signer" \
  "${DUAL_SIGNER_ERROR}" \
  || die "dual-signer verification receipt did not fail at signer cardinality"

THREE_FIELD_JSON="${TEST_ROOT}/verification-three-fields.json"
/usr/bin/plutil -create xml1 "${THREE_FIELD_JSON}"
/usr/bin/plutil -insert source_head -string "${SOURCE_HEAD}" "${THREE_FIELD_JSON}"
/usr/bin/plutil -insert dirty -bool false "${THREE_FIELD_JSON}"
/usr/bin/plutil -insert archive_verified -bool true "${THREE_FIELD_JSON}"
/usr/bin/plutil -convert json "${THREE_FIELD_JSON}"
sign_receipt "${THREE_FIELD_JSON}" verification "${THREE_FIELD_JSON}.cms"
if INFLOW_VERIFICATION_SIGNER_SHA256="${VERIFICATION_PIN}" \
  "${WORKFLOW}" verify-verification-receipt \
  "${THREE_FIELD_JSON}" "${THREE_FIELD_JSON}.cms" "${SOURCE_HEAD}" \
  "${VERIFICATION_ARCHIVE_ZIP}" "${VERIFICATION_APP_FIELDS}" >/dev/null 2>&1
then
  die "handwritten three-field verification evidence was accepted"
fi

MISSING_FIELD_JSON="${TEST_ROOT}/verification-missing-field.json"
/bin/cp "${VERIFICATION_JSON}" "${MISSING_FIELD_JSON}"
/usr/bin/plutil -remove analyze_xcresult_sha256 "${MISSING_FIELD_JSON}"
sign_receipt "${MISSING_FIELD_JSON}" verification "${MISSING_FIELD_JSON}.cms"
if INFLOW_VERIFICATION_SIGNER_SHA256="${VERIFICATION_PIN}" \
  "${WORKFLOW}" verify-verification-receipt \
  "${MISSING_FIELD_JSON}" "${MISSING_FIELD_JSON}.cms" "${SOURCE_HEAD}" \
  "${VERIFICATION_ARCHIVE_ZIP}" "${VERIFICATION_APP_FIELDS}" >/dev/null 2>&1
then
  die "verification evidence with a missing field was accepted"
fi

EXTRA_FIELD_JSON="${TEST_ROOT}/verification-extra-field.json"
/bin/cp "${VERIFICATION_JSON}" "${EXTRA_FIELD_JSON}"
/usr/bin/plutil -insert unreviewed_override -bool true "${EXTRA_FIELD_JSON}"
sign_receipt "${EXTRA_FIELD_JSON}" verification "${EXTRA_FIELD_JSON}.cms"
if INFLOW_VERIFICATION_SIGNER_SHA256="${VERIFICATION_PIN}" \
  "${WORKFLOW}" verify-verification-receipt \
  "${EXTRA_FIELD_JSON}" "${EXTRA_FIELD_JSON}.cms" "${SOURCE_HEAD}" \
  "${VERIFICATION_ARCHIVE_ZIP}" "${VERIFICATION_APP_FIELDS}" >/dev/null 2>&1
then
  die "verification evidence with an extra field was accepted"
fi

TAMPERED_VERIFICATION_JSON="${TEST_ROOT}/verification-tampered.json"
/bin/cp "${VERIFICATION_JSON}" "${TAMPERED_VERIFICATION_JSON}"
/usr/bin/plutil -replace analyze_passed -bool false "${TAMPERED_VERIFICATION_JSON}"
if INFLOW_VERIFICATION_SIGNER_SHA256="${VERIFICATION_PIN}" \
  "${WORKFLOW}" verify-verification-receipt \
  "${TAMPERED_VERIFICATION_JSON}" "${VERIFICATION_JSON}.cms" "${SOURCE_HEAD}" \
  "${VERIFICATION_ARCHIVE_ZIP}" "${VERIFICATION_APP_FIELDS}" >/dev/null 2>&1
then
  die "verification content modified after signing was accepted"
fi

SHRUNK_VERIFICATION_JSON="${TEST_ROOT}/verification-shrunk.json"
/bin/cp "${VERIFICATION_JSON}" "${SHRUNK_VERIFICATION_JSON}"
/usr/bin/plutil -replace macos_test_count -integer 1 "${SHRUNK_VERIFICATION_JSON}"
sign_receipt "${SHRUNK_VERIFICATION_JSON}" verification "${SHRUNK_VERIFICATION_JSON}.cms"
if INFLOW_VERIFICATION_SIGNER_SHA256="${VERIFICATION_PIN}" \
  "${WORKFLOW}" verify-verification-receipt \
  "${SHRUNK_VERIFICATION_JSON}" "${SHRUNK_VERIFICATION_JSON}.cms" "${SOURCE_HEAD}" \
  "${VERIFICATION_ARCHIVE_ZIP}" "${VERIFICATION_APP_FIELDS}" >/dev/null 2>&1
then
  die "signed verification receipt with a one-test suite was accepted"
fi

WRONG_TOOL_JSON="${TEST_ROOT}/verification-wrong-tool.json"
/bin/cp "${VERIFICATION_JSON}" "${WRONG_TOOL_JSON}"
/usr/bin/plutil -replace cargo_lock_sha256 -string "$(hash_character 9)" "${WRONG_TOOL_JSON}"
sign_receipt "${WRONG_TOOL_JSON}" verification "${WRONG_TOOL_JSON}.cms"
if INFLOW_VERIFICATION_SIGNER_SHA256="${VERIFICATION_PIN}" \
  "${WORKFLOW}" verify-verification-receipt \
  "${WRONG_TOOL_JSON}" "${WRONG_TOOL_JSON}.cms" "${SOURCE_HEAD}" \
  "${VERIFICATION_ARCHIVE_ZIP}" "${VERIFICATION_APP_FIELDS}" >/dev/null 2>&1
then
  die "verification evidence for a different Cargo.lock was accepted"
fi

WRONG_APP_FIELDS="${TEST_ROOT}/verification-wrong-app-fields.json"
/bin/cp "${VERIFICATION_APP_FIELDS}" "${WRONG_APP_FIELDS}"
/usr/bin/plutil -replace app_binary_sha256 -string "$(hash_character 8)" "${WRONG_APP_FIELDS}"
if INFLOW_VERIFICATION_SIGNER_SHA256="${VERIFICATION_PIN}" \
  "${WORKFLOW}" verify-verification-receipt \
  "${VERIFICATION_JSON}" "${VERIFICATION_JSON}.cms" "${SOURCE_HEAD}" \
  "${VERIFICATION_ARCHIVE_ZIP}" "${WRONG_APP_FIELDS}" >/dev/null 2>&1
then
  die "verification evidence was accepted for a different App binary"
fi

OTHER_ARCHIVE_ROOT="${TEST_ROOT}/other-archive-payload"
OTHER_ARCHIVE_ZIP="${TEST_ROOT}/other-archive.zip"
/bin/mkdir -p "${OTHER_ARCHIVE_ROOT}"
printf '%s\n' other >"${OTHER_ARCHIVE_ROOT}/evidence.txt"
/usr/bin/ditto -c -k --keepParent "${OTHER_ARCHIVE_ROOT}" "${OTHER_ARCHIVE_ZIP}"
if INFLOW_VERIFICATION_SIGNER_SHA256="${VERIFICATION_PIN}" \
  "${WORKFLOW}" verify-verification-receipt \
  "${VERIFICATION_JSON}" "${VERIFICATION_JSON}.cms" "${SOURCE_HEAD}" \
  "${OTHER_ARCHIVE_ZIP}" "${VERIFICATION_APP_FIELDS}" >/dev/null 2>&1
then
  die "verification evidence was accepted for a different Archive ZIP"
fi

if INFLOW_VERIFICATION_SIGNER_SHA256="$(hash_character 0)" \
  "${WORKFLOW}" verify-verification-receipt \
  "${VERIFICATION_JSON}" "${VERIFICATION_JSON}.cms" "${SOURCE_HEAD}" \
  "${VERIFICATION_ARCHIVE_ZIP}" "${VERIFICATION_APP_FIELDS}" >/dev/null 2>&1
then
  die "verification evidence from an unpinned signer was accepted"
fi

printf '%s\n' not-a-zip >"${TEST_ROOT}/-h"
if (cd "${TEST_ROOT}" && "${WORKFLOW}" verify-zip -h >/dev/null 2>&1); then
  die "option-like relative ZIP path was accepted"
fi

"${WORKFLOW}" verify-safe-zip-payload \
  "${VERIFICATION_ARCHIVE_ZIP}" >/dev/null
SYMLINK_PAYLOAD="${TEST_ROOT}/symlink-payload"
SYMLINK_ZIP="${TEST_ROOT}/symlink-payload.zip"
/bin/mkdir -p "${SYMLINK_PAYLOAD}"
/bin/ln -s "${VERIFICATION_ARCHIVE_ROOT}" "${SYMLINK_PAYLOAD}/Inflow.app"
/usr/bin/ditto -c -k --keepParent "${SYMLINK_PAYLOAD}" "${SYMLINK_ZIP}"
if "${WORKFLOW}" verify-safe-zip-payload "${SYMLINK_ZIP}" >/dev/null 2>&1; then
  die "ZIP payload containing an absolute symlink was accepted"
fi

if INFLOW_PERFORMANCE_SIGNER_SHA256="${PERFORMANCE_PIN}" \
   INFLOW_PRODUCT_APPROVAL_SIGNER_SHA256="${PRODUCT_PIN}" \
   "${WORKFLOW}" verify-evidence-receipts \
     "${SOURCE_HEAD}" "${PERFORMANCE_JSON}" "${PERFORMANCE_JSON}.cms" \
     "${PRODUCT_JSON}" "${PRODUCT_JSON}.cms" >/dev/null 2>&1
then
  die "the repository's OPEN performance manifest was accepted for release"
fi

COMPLETE_MANIFEST="${TEST_ROOT}/performance-manifest-complete.json"
/bin/cp "${MANIFEST}" "${COMPLETE_MANIFEST}"
/usr/bin/plutil -replace authoritative_target.operating_system_build \
  -string 23A344 "${COMPLETE_MANIFEST}"
/usr/bin/plutil -replace fixture.full_fixture_status \
  -string passed "${COMPLETE_MANIFEST}"
/usr/bin/plutil -replace fixture.full_fixture_sha256 \
  -string "$(hash_character 3)" "${COMPLETE_MANIFEST}"
/usr/bin/plutil -replace fixture.structure_distribution.status \
  -string passed "${COMPLETE_MANIFEST}"
/usr/bin/plutil -replace fixture.structure_distribution.sha256 \
  -string "$(hash_character 1)" "${COMPLETE_MANIFEST}"
/usr/bin/plutil -replace fixture.local_images.status \
  -string passed "${COMPLETE_MANIFEST}"
/usr/bin/plutil -replace fixture.local_images.corpus_sha256 \
  -string "$(hash_character 2)" "${COMPLETE_MANIFEST}"
/usr/bin/plutil -replace performance_budgets.status \
  -string approved "${COMPLETE_MANIFEST}"
/usr/bin/plutil -replace performance_budgets.aggregate_rss_peak_bytes \
  -integer 500000000 "${COMPLETE_MANIFEST}"
/usr/bin/plutil -replace performance_budgets.aggregate_cpu_window_percent \
  -float 200 "${COMPLETE_MANIFEST}"
/usr/bin/plutil -convert json "${COMPLETE_MANIFEST}"

COMPLETE_PERFORMANCE_JSON="${TEST_ROOT}/performance-complete.json"
write_performance_receipt "${COMPLETE_PERFORMANCE_JSON}" 30
/usr/bin/plutil -replace manifest_sha256 -string \
  "$(sha256_file "${COMPLETE_MANIFEST}")" "${COMPLETE_PERFORMANCE_JSON}"
/usr/bin/plutil -replace macos_build -string 23A344 \
  "${COMPLETE_PERFORMANCE_JSON}"
/usr/bin/plutil -convert json "${COMPLETE_PERFORMANCE_JSON}"
sign_receipt \
  "${COMPLETE_PERFORMANCE_JSON}" performance "${COMPLETE_PERFORMANCE_JSON}.cms"
INFLOW_PERFORMANCE_SIGNER_SHA256="${PERFORMANCE_PIN}" \
  "${WORKFLOW}" verify-performance-receipt \
  "${COMPLETE_PERFORMANCE_JSON}" "${COMPLETE_PERFORMANCE_JSON}.cms" \
  "${SOURCE_HEAD}" "${COMPLETE_MANIFEST}" >/dev/null

INFLOW_PRODUCT_APPROVAL_SIGNER_SHA256="${PRODUCT_PIN}" \
  "${WORKFLOW}" verify-product-baseline-receipt \
  "${PRODUCT_JSON}" "${PRODUCT_JSON}.cms" "${SOURCE_HEAD}" >/dev/null

EXTRA_PERFORMANCE_JSON="${TEST_ROOT}/performance-extra-field.json"
/bin/cp "${COMPLETE_PERFORMANCE_JSON}" "${EXTRA_PERFORMANCE_JSON}"
/usr/bin/plutil -insert unreviewed_override -bool true "${EXTRA_PERFORMANCE_JSON}"
sign_receipt \
  "${EXTRA_PERFORMANCE_JSON}" performance "${EXTRA_PERFORMANCE_JSON}.cms"
if INFLOW_PERFORMANCE_SIGNER_SHA256="${PERFORMANCE_PIN}" \
   "${WORKFLOW}" verify-performance-receipt \
     "${EXTRA_PERFORMANCE_JSON}" "${EXTRA_PERFORMANCE_JSON}.cms" \
     "${SOURCE_HEAD}" "${COMPLETE_MANIFEST}" >/dev/null 2>&1
then
  die "signed performance evidence outside the closed-world schema was accepted"
fi

WRONG_PERFORMANCE_TYPE_JSON="${TEST_ROOT}/performance-wrong-type.json"
/bin/cp "${COMPLETE_PERFORMANCE_JSON}" "${WRONG_PERFORMANCE_TYPE_JSON}"
/usr/bin/plutil -replace measured_runs -string 30 "${WRONG_PERFORMANCE_TYPE_JSON}"
sign_receipt \
  "${WRONG_PERFORMANCE_TYPE_JSON}" performance "${WRONG_PERFORMANCE_TYPE_JSON}.cms"
if INFLOW_PERFORMANCE_SIGNER_SHA256="${PERFORMANCE_PIN}" \
   "${WORKFLOW}" verify-performance-receipt \
     "${WRONG_PERFORMANCE_TYPE_JSON}" "${WRONG_PERFORMANCE_TYPE_JSON}.cms" \
     "${SOURCE_HEAD}" "${COMPLETE_MANIFEST}" >/dev/null 2>&1
then
  die "signed performance evidence with a string run count was accepted"
fi

EXTRA_PRODUCT_JSON="${TEST_ROOT}/product-extra-field.json"
/bin/cp "${PRODUCT_JSON}" "${EXTRA_PRODUCT_JSON}"
/usr/bin/plutil -insert unreviewed_override -bool true "${EXTRA_PRODUCT_JSON}"
sign_receipt "${EXTRA_PRODUCT_JSON}" product "${EXTRA_PRODUCT_JSON}.cms"
if INFLOW_PRODUCT_APPROVAL_SIGNER_SHA256="${PRODUCT_PIN}" \
   "${WORKFLOW}" verify-product-baseline-receipt \
     "${EXTRA_PRODUCT_JSON}" "${EXTRA_PRODUCT_JSON}.cms" \
     "${SOURCE_HEAD}" >/dev/null 2>&1
then
  die "signed product approval outside the closed-world schema was accepted"
fi

WRONG_PRODUCT_TYPE_JSON="${TEST_ROOT}/product-wrong-type.json"
/bin/cp "${PRODUCT_JSON}" "${WRONG_PRODUCT_TYPE_JSON}"
/usr/bin/plutil -replace schema_version -string 1 "${WRONG_PRODUCT_TYPE_JSON}"
sign_receipt "${WRONG_PRODUCT_TYPE_JSON}" product "${WRONG_PRODUCT_TYPE_JSON}.cms"
if INFLOW_PRODUCT_APPROVAL_SIGNER_SHA256="${PRODUCT_PIN}" \
   "${WORKFLOW}" verify-product-baseline-receipt \
     "${WRONG_PRODUCT_TYPE_JSON}" "${WRONG_PRODUCT_TYPE_JSON}.cms" \
     "${SOURCE_HEAD}" >/dev/null 2>&1
then
  die "signed product approval with a string schema version was accepted"
fi

TAMPERED_JSON="${TEST_ROOT}/performance-tampered.json"
/bin/cp "${PERFORMANCE_JSON}" "${TAMPERED_JSON}"
/usr/bin/plutil -replace measured_runs -integer 29 "${TAMPERED_JSON}"
if INFLOW_PERFORMANCE_SIGNER_SHA256="${PERFORMANCE_PIN}" \
   "${WORKFLOW}" verify-performance-receipt \
     "${TAMPERED_JSON}" "${PERFORMANCE_JSON}.cms" \
     "${SOURCE_HEAD}" "${COMPLETE_MANIFEST}" >/dev/null 2>&1
then
  die "tampered signed performance content was accepted"
fi

INCOMPLETE_JSON="${TEST_ROOT}/performance-incomplete.json"
write_performance_receipt "${INCOMPLETE_JSON}" 29
/usr/bin/plutil -replace manifest_sha256 -string \
  "$(sha256_file "${COMPLETE_MANIFEST}")" "${INCOMPLETE_JSON}"
/usr/bin/plutil -replace macos_build -string 23A344 "${INCOMPLETE_JSON}"
/usr/bin/plutil -convert json "${INCOMPLETE_JSON}"
sign_receipt "${INCOMPLETE_JSON}" performance "${INCOMPLETE_JSON}.cms"
if INFLOW_PERFORMANCE_SIGNER_SHA256="${PERFORMANCE_PIN}" \
   "${WORKFLOW}" verify-performance-receipt \
     "${INCOMPLETE_JSON}" "${INCOMPLETE_JSON}.cms" \
     "${SOURCE_HEAD}" "${COMPLETE_MANIFEST}" >/dev/null 2>&1
then
  die "signed evidence with 29 measured runs was accepted"
fi

WRONG_PROTOCOL_JSON="${TEST_ROOT}/performance-wrong-protocol.json"
write_performance_receipt "${WRONG_PROTOCOL_JSON}" 30
/usr/bin/plutil -replace manifest_sha256 -string \
  "$(sha256_file "${COMPLETE_MANIFEST}")" "${WRONG_PROTOCOL_JSON}"
/usr/bin/plutil -replace macos_build -string 23A344 "${WRONG_PROTOCOL_JSON}"
/usr/bin/plutil -replace warm_idle_seconds -integer 9 "${WRONG_PROTOCOL_JSON}"
/usr/bin/plutil -convert json "${WRONG_PROTOCOL_JSON}"
sign_receipt "${WRONG_PROTOCOL_JSON}" performance "${WRONG_PROTOCOL_JSON}.cms"
if INFLOW_PERFORMANCE_SIGNER_SHA256="${PERFORMANCE_PIN}" \
   "${WORKFLOW}" verify-performance-receipt \
     "${WRONG_PROTOCOL_JSON}" "${WRONG_PROTOCOL_JSON}.cms" \
     "${SOURCE_HEAD}" "${COMPLETE_MANIFEST}" >/dev/null 2>&1
then
  die "signed performance evidence with the wrong warm-open protocol was accepted"
fi

WRONG_OS_JSON="${TEST_ROOT}/performance-wrong-os.json"
write_performance_receipt "${WRONG_OS_JSON}" 30
/usr/bin/plutil -replace manifest_sha256 -string \
  "$(sha256_file "${COMPLETE_MANIFEST}")" "${WRONG_OS_JSON}"
/usr/bin/plutil -replace macos_build -string 23A344 "${WRONG_OS_JSON}"
/usr/bin/plutil -replace macos_version -string 14.1 "${WRONG_OS_JSON}"
/usr/bin/plutil -convert json "${WRONG_OS_JSON}"
sign_receipt "${WRONG_OS_JSON}" performance "${WRONG_OS_JSON}.cms"
if INFLOW_PERFORMANCE_SIGNER_SHA256="${PERFORMANCE_PIN}" \
   "${WORKFLOW}" verify-performance-receipt \
     "${WRONG_OS_JSON}" "${WRONG_OS_JSON}.cms" \
     "${SOURCE_HEAD}" "${COMPLETE_MANIFEST}" >/dev/null 2>&1
then
  die "signed macOS 14.1 performance evidence was accepted for the exact 14.0 target"
fi

WRONG_BUILD_JSON="${TEST_ROOT}/performance-wrong-build.json"
/bin/cp "${COMPLETE_PERFORMANCE_JSON}" "${WRONG_BUILD_JSON}"
/usr/bin/plutil -replace macos_build -string 23A999 "${WRONG_BUILD_JSON}"
sign_receipt "${WRONG_BUILD_JSON}" performance "${WRONG_BUILD_JSON}.cms"
if INFLOW_PERFORMANCE_SIGNER_SHA256="${PERFORMANCE_PIN}" \
   "${WORKFLOW}" verify-performance-receipt \
     "${WRONG_BUILD_JSON}" "${WRONG_BUILD_JSON}.cms" \
     "${SOURCE_HEAD}" "${COMPLETE_MANIFEST}" >/dev/null 2>&1
then
  die "signed performance evidence for the wrong exact macOS build was accepted"
fi

OVER_BUDGET_JSON="${TEST_ROOT}/performance-over-budget.json"
/bin/cp "${COMPLETE_PERFORMANCE_JSON}" "${OVER_BUDGET_JSON}"
/usr/bin/plutil -replace preview_update_p95_milliseconds -float 301 \
  "${OVER_BUDGET_JSON}"
sign_receipt "${OVER_BUDGET_JSON}" performance "${OVER_BUDGET_JSON}.cms"
if INFLOW_PERFORMANCE_SIGNER_SHA256="${PERFORMANCE_PIN}" \
   "${WORKFLOW}" verify-performance-receipt \
     "${OVER_BUDGET_JSON}" "${OVER_BUDGET_JSON}.cms" \
     "${SOURCE_HEAD}" "${COMPLETE_MANIFEST}" >/dev/null 2>&1
then
  die "signed performance evidence above the approved budget was accepted"
fi

if INFLOW_PERFORMANCE_SIGNER_SHA256="$(hash_character f)" \
   "${WORKFLOW}" verify-performance-receipt \
     "${COMPLETE_PERFORMANCE_JSON}" "${COMPLETE_PERFORMANCE_JSON}.cms" \
     "${SOURCE_HEAD}" "${COMPLETE_MANIFEST}" >/dev/null 2>&1
then
  die "untrusted performance signer was accepted"
fi

UNAPPROVED_JSON="${TEST_ROOT}/product-unapproved.json"
write_product_receipt "${UNAPPROVED_JSON}" pending
sign_receipt "${UNAPPROVED_JSON}" product "${UNAPPROVED_JSON}.cms"
if INFLOW_PRODUCT_APPROVAL_SIGNER_SHA256="${PRODUCT_PIN}" \
   "${WORKFLOW}" verify-product-baseline-receipt \
     "${UNAPPROVED_JSON}" "${UNAPPROVED_JSON}.cms" \
     "${SOURCE_HEAD}" >/dev/null 2>&1
then
  die "signed but unapproved product baseline was accepted"
fi

if "${WORKFLOW}" verify-performance-receipt \
  "${COMPLETE_PERFORMANCE_JSON}" "${COMPLETE_PERFORMANCE_JSON}.cms" \
  "${SOURCE_HEAD}" "${COMPLETE_MANIFEST}" >/dev/null 2>&1
then
  die "performance evidence was accepted without a protected signer fingerprint"
fi

if "${WORKFLOW}" verify-product-baseline-receipt \
  "${PRODUCT_JSON}" "${PRODUCT_JSON}.cms" "${SOURCE_HEAD}" >/dev/null 2>&1
then
  die "product approval was accepted without a protected signer fingerprint"
fi

RELEASE_TEAM=TESTTEAM1
RELEASE_BUNDLE_ID=com.inflow.desktop
PREVIOUS_JSON="${TEST_ROOT}/previous-release.json"
make_release_signer previous "${RELEASE_TEAM}"
PREVIOUS_SIGNER_SHA256="$(certificate_sha256 "${TEST_ROOT}/previous.pem")"
write_release_manifest \
  "${PREVIOUS_JSON}" 1 "${RELEASE_TEAM}" "${RELEASE_BUNDLE_ID}" \
  "${TEST_ROOT}/previous.pem"
sign_receipt "${PREVIOUS_JSON}" previous "${PREVIOUS_JSON}.cms"
"${WORKFLOW}" verify-predecessor-identity \
  "${PREVIOUS_JSON}" "${PREVIOUS_JSON}.cms" 1 \
  "${RELEASE_TEAM}" "${RELEASE_BUNDLE_ID}" "${PREVIOUS_SIGNER_SHA256}" \
  >/dev/null

if "${WORKFLOW}" verify-release-manifest \
  "${PREVIOUS_JSON}" "${PREVIOUS_JSON}.cms" \
  "${VERIFICATION_ARCHIVE_ZIP}" "${VERIFICATION_ARCHIVE_ZIP}" \
  >/dev/null 2>&1
then
  die "public verification accepted a release while the versioned trust root is OPEN"
fi
if INFLOW_RELEASE_SIGNER_SHA256="${PREVIOUS_SIGNER_SHA256}" \
   INFLOW_RELEASE_TEAM_ID="${RELEASE_TEAM}" \
   INFLOW_RELEASE_BUNDLE_ID="${RELEASE_BUNDLE_ID}" \
   "${WORKFLOW}" verify-release-manifest \
     "${PREVIOUS_JSON}" "${PREVIOUS_JSON}.cms" \
     "${VERIFICATION_ARCHIVE_ZIP}" "${VERIFICATION_ARCHIVE_ZIP}" \
     >/dev/null 2>&1
then
  die "public verification accepted a caller-selected release identity"
fi

OTHER_TEAM_JSON="${TEST_ROOT}/other-team-release.json"
make_release_signer otherteam OTHERTEAM9
write_release_manifest \
  "${OTHER_TEAM_JSON}" 1 OTHERTEAM9 "${RELEASE_BUNDLE_ID}" \
  "${TEST_ROOT}/otherteam.pem"
sign_receipt "${OTHER_TEAM_JSON}" otherteam "${OTHER_TEAM_JSON}.cms"
if "${WORKFLOW}" verify-predecessor-identity \
  "${OTHER_TEAM_JSON}" "${OTHER_TEAM_JSON}.cms" 1 \
  "${RELEASE_TEAM}" "${RELEASE_BUNDLE_ID}" "${PREVIOUS_SIGNER_SHA256}" \
  >/dev/null 2>&1
then
  die "predecessor signed by another certificate and Team ID was accepted"
fi

SAME_TEAM_OTHER_CERT_JSON="${TEST_ROOT}/same-team-other-certificate.json"
make_release_signer rotated "${RELEASE_TEAM}"
write_release_manifest \
  "${SAME_TEAM_OTHER_CERT_JSON}" 1 "${RELEASE_TEAM}" "${RELEASE_BUNDLE_ID}" \
  "${TEST_ROOT}/rotated.pem"
sign_receipt \
  "${SAME_TEAM_OTHER_CERT_JSON}" rotated "${SAME_TEAM_OTHER_CERT_JSON}.cms"
if "${WORKFLOW}" verify-predecessor-identity \
  "${SAME_TEAM_OTHER_CERT_JSON}" "${SAME_TEAM_OTHER_CERT_JSON}.cms" 1 \
  "${RELEASE_TEAM}" "${RELEASE_BUNDLE_ID}" "${PREVIOUS_SIGNER_SHA256}" \
  >/dev/null 2>&1
then
  die "predecessor signed by an unpinned certificate in the same Team ID was accepted"
fi

WRONG_BUNDLE_JSON="${TEST_ROOT}/wrong-bundle-release.json"
write_release_manifest \
  "${WRONG_BUNDLE_JSON}" 1 "${RELEASE_TEAM}" com.inflow.other \
  "${TEST_ROOT}/previous.pem"
sign_receipt "${WRONG_BUNDLE_JSON}" previous "${WRONG_BUNDLE_JSON}.cms"
if "${WORKFLOW}" verify-predecessor-identity \
  "${WRONG_BUNDLE_JSON}" "${WRONG_BUNDLE_JSON}.cms" 1 \
  "${RELEASE_TEAM}" "${RELEASE_BUNDLE_ID}" "${PREVIOUS_SIGNER_SHA256}" \
  >/dev/null 2>&1
then
  die "predecessor from a different bundle ID was accepted"
fi

echo "release evidence and predecessor-identity gates passed positive and fail-closed regression cases"
