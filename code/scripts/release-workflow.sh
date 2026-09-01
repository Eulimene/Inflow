#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Inflow deferred direct-distribution release workflow

This workflow is retained for a future public-distribution decision. It is not
part of the current personal internal milestone or its completion criteria.

Usage:
  release-workflow.sh check
  release-workflow.sh candidate [output-root]
  release-workflow.sh verify-local-archive ARCHIVE
  release-workflow.sh verify-zip ZIP
  release-workflow.sh verify-safe-zip-payload ZIP
  release-workflow.sh developer-id-archive TEAM_ID [output-root]
  release-workflow.sh notarize ARCHIVE KEYCHAIN_PROFILE [output-root]
  release-workflow.sh verify-evidence-receipts SOURCE_HEAD PERFORMANCE_EVIDENCE PERFORMANCE_CMS PRODUCT_BASELINE_EVIDENCE PRODUCT_BASELINE_CMS
  release-workflow.sh verify-performance-receipt EVIDENCE CMS SOURCE_HEAD MANIFEST
  release-workflow.sh verify-product-baseline-receipt EVIDENCE CMS SOURCE_HEAD
  release-workflow.sh verify-predecessor-identity MANIFEST CMS_SIGNATURE EXPECTED_SEQUENCE EXPECTED_TEAM_ID EXPECTED_BUNDLE_ID EXPECTED_SIGNER_SHA256
  release-workflow.sh verify-verification-receipt EVIDENCE CMS SOURCE_HEAD ARCHIVE_ZIP EXPECTED_APP_FIELDS
  release-workflow.sh verify-trusted-verification-receipt EVIDENCE CMS SOURCE_HEAD ARCHIVE_ZIP EXPECTED_APP_FIELDS
  release-workflow.sh seal-release SEQUENCE APP DISTRIBUTION_ZIP ARCHIVE_ZIP VERIFICATION_EVIDENCE VERIFICATION_CMS PERFORMANCE_EVIDENCE PERFORMANCE_CMS PRODUCT_BASELINE_EVIDENCE PRODUCT_BASELINE_CMS OUTPUT_DIRECTORY
  release-workflow.sh verify-release-manifest MANIFEST CMS_SIGNATURE DISTRIBUTION_ZIP ARCHIVE_ZIP
  release-workflow.sh verify-notarized-app APP
  release-workflow.sh open-archive ARCHIVE

Commands:
  check
      Run every deferred repository-controlled release gate with a temporary
      unsigned archive. This is not the personal milestone gate.

  candidate [output-root]
      Run every gate once, keep a fresh unsigned local archive, compress it, and
      print/write its SHA-256. The default root is code/build/releases.

  verify-local-archive ARCHIVE
      Recheck a retained unsigned local archive without rebuilding it.

  verify-zip ZIP
      Check ZIP structure and, when ZIP.sha256 exists, verify its SHA-256.

  verify-safe-zip-payload ZIP
      Regression-test ZIP extraction policy: only regular files/directories and
      no symlink or traversal entry may survive inside the private payload root.

  developer-id-archive TEAM_ID [output-root]
      Build a fresh Developer ID archive using an installed matching certificate,
      then run the full deferred signed-archive gate. The default root is
      code/build/releases.

  notarize ARCHIVE KEYCHAIN_PROFILE [output-root]
      Verify a Developer ID archive, copy its app, submit it with notarytool,
      save the notary result and log, staple the ticket, assess it with Gatekeeper,
      then create the final ZIP and SHA-256. The Keychain profile must already
      exist (create it with `xcrun notarytool store-credentials`).

  verify-evidence-receipts SOURCE_HEAD PERFORMANCE_EVIDENCE PERFORMANCE_CMS PRODUCT_BASELINE_EVIDENCE PRODUCT_BASELINE_CMS
      Verify both detached evidence signatures against protected signer
      fingerprints and validate every release-blocking field against SOURCE_HEAD
      and the repository performance manifest. This does not create evidence.

  verify-performance-receipt EVIDENCE CMS SOURCE_HEAD MANIFEST
      Regression-test a pinned performance receipt against an explicit complete
      manifest. Production seal-release always uses the repository manifest.

  verify-product-baseline-receipt EVIDENCE CMS SOURCE_HEAD
      Regression-test a pinned product approval receipt independently.

  verify-predecessor-identity MANIFEST CMS_SIGNATURE EXPECTED_SEQUENCE EXPECTED_TEAM_ID EXPECTED_BUNDLE_ID EXPECTED_SIGNER_SHA256
      Regression-testable identity contract for a predecessor manifest. It
      cryptographically verifies the detached content and requires the CMS leaf
      certificate, declared certificate fingerprint/subject, Team ID, bundle ID,
      direct-distribution channel/profile, and sequence to match. This command
      intentionally does not establish platform trust; seal-release additionally
      performs the macOS trust-policy check before applying this contract.

  verify-verification-receipt EVIDENCE CMS SOURCE_HEAD ARCHIVE_ZIP EXPECTED_APP_FIELDS
      Regression-testable closed-world contract for the repository verification
      receipt. It verifies detached content and the protected signer pin, then
      binds the exact source, archive ZIP, toolchain, tests, Analyze result, and
      expected signed-App fields. Production seal-release additionally requires
      macOS CMS trust for the receipt signer.

  verify-trusted-verification-receipt EVIDENCE CMS SOURCE_HEAD ARCHIVE_ZIP EXPECTED_APP_FIELDS
      Apply the same contract and also require the CMS signer to satisfy the
      current macOS trust policy. This is the verification performed by seal-release.

  seal-release SEQUENCE APP DISTRIBUTION_ZIP ARCHIVE_ZIP VERIFICATION_EVIDENCE VERIFICATION_CMS PERFORMANCE_EVIDENCE PERFORMANCE_CMS PRODUCT_BASELINE_EVIDENCE PRODUCT_BASELINE_CMS OUTPUT_DIRECTORY
      Refuse incomplete, unsigned, or mismatched evidence, enforce an adjacent
      release sequence, write a release provenance manifest, and sign it as
      detached SHA-256 CMS with the Developer ID identity already used by APP.
      Repository verification, performance, and product receipts must carry
      detached DER CMS signatures. Their signer certificate SHA-256 values must
      be supplied by protected release configuration. Sequence 1 has no predecessor.
      Later releases require INFLOW_PREVIOUS_RELEASE_MANIFEST and
      INFLOW_PREVIOUS_RELEASE_SIGNATURE to point to the last signed release.

  verify-release-manifest MANIFEST CMS_SIGNATURE DISTRIBUTION_ZIP ARCHIVE_ZIP
      Verify the detached manifest signature, closed-world fields, trusted
      minimum sequence, and both bound artifact hashes against the versioned
      repository trust root. Caller-selected identity environment values are rejected.

  verify-notarized-app APP
      Verify Developer ID signature, hardened runtime, stapled ticket, and
      Gatekeeper acceptance for an exported app.

  open-archive ARCHIVE
      Open the Inflow app contained in an archive for manual acceptance testing.

This script never accepts Apple credentials or passwords and never replaces an
existing archive/output directory.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

require_argument_count() {
  actual="$1"
  minimum="$2"
  maximum="$3"
  if [ "${actual}" -lt "${minimum}" ] || [ "${actual}" -gt "${maximum}" ]; then
    usage >&2
    exit 64
  fi
}

require_valid_manual_update_url() {
  update_url="$1"
  case "${update_url}" in
    *[[:space:]]*)
      die "INFLOW_MANUAL_UPDATE_URL must not contain whitespace"
      ;;
  esac
  printf '%s' "${update_url}" \
    | LC_ALL=C /usr/bin/grep -Eq '^https://[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9](/[A-Za-z0-9._~!$&()*+,;=%/-]*)?$' \
    || die "INFLOW_MANUAL_UPDATE_URL must be a fixed HTTPS URL without credentials, port, query, fragment, whitespace, or non-ASCII bytes"
  case "${update_url}" in
    *..* | *'@'* | *'?'* | *'#'*)
      die "INFLOW_MANUAL_UPDATE_URL contains a forbidden authority or URL component"
      ;;
  esac
}

make_absolute_directory() {
  directory="$1"
  /bin/mkdir -p "${directory}"
  (CDPATH= cd -- "${directory}" && pwd)
}

fresh_output_directory() {
  root="$1"
  label="$2"
  timestamp="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
  output_directory="${root}/${label}-${timestamp}"
  [ ! -e "${output_directory}" ] \
    || die "refusing to replace existing output: ${output_directory}"
  /bin/mkdir -p "${output_directory}"
  echo "${output_directory}"
}

archive_app_path() {
  echo "$1/Products/Applications/Inflow.app"
}

signature_details() {
  /usr/bin/codesign -dvv "$1" 2>&1
}

require_developer_id_signature() {
  app_path="$1"
  expected_team_id="${2:-}"
  [ -d "${app_path}" ] || die "Inflow app does not exist: ${app_path}"
  /usr/bin/codesign --verify --deep --strict "${app_path}" \
    || die "Developer ID signature verification failed"
  details="$(signature_details "${app_path}")"
  signing_authority="$(
    echo "${details}" | /usr/bin/awk -F= '$1 == "Authority" { print $2; exit }'
  )"
  case "${signing_authority}" in
    "Developer ID Application:"*) ;;
    *) die "app is not signed with a Developer ID Application identity" ;;
  esac
  if [ -n "${expected_team_id}" ]; then
    case "${signing_authority}" in
      *"(${expected_team_id})") ;;
      *) die "Developer ID signature does not belong to team ${expected_team_id}" ;;
    esac
  fi
  echo "${details}" | /usr/bin/grep -Eq 'flags=.*runtime' \
    || die "app signature is missing hardened runtime"
  signature_timestamp="$(
    echo "${details}" | /usr/bin/awk -F= '$1 == "Timestamp" { print $2; exit }'
  )"
  [ -n "${signature_timestamp}" ] && [ "${signature_timestamp}" != "none" ] \
    || die "app signature is missing a secure timestamp"
}

verify_notarized_app() {
  app_path="$1"
  require_developer_id_signature "${app_path}"
  /usr/bin/xcrun stapler validate "${app_path}"
  /usr/sbin/spctl --assess --type execute --verbose=4 "${app_path}"
}

write_zip_and_hash() {
  source_path="$1"
  zip_path="$2"
  [ ! -e "${zip_path}" ] || die "refusing to replace existing ZIP: ${zip_path}"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "${source_path}" "${zip_path}"
  /usr/bin/unzip -tq -- "${zip_path}"
  hash_value="$(sha256 "${zip_path}")"
  printf '%s  %s\n' "${hash_value}" "$(/usr/bin/basename "${zip_path}")" \
    >"${zip_path}.sha256"
  echo "ZIP: ${zip_path}"
  echo "SHA-256: ${hash_value}"
  echo "checksum file: ${zip_path}.sha256"
}

verify_zip() {
  zip_path="$1"
  require_absolute_regular_file "${zip_path}" "ZIP"
  /usr/bin/unzip -tq -- "${zip_path}" \
    || die "ZIP structure is invalid: ${zip_path}"
  actual_hash="$(sha256 "${zip_path}")"
  checksum_path="${zip_path}.sha256"
  if [ -f "${checksum_path}" ]; then
    expected_hash="$(/usr/bin/awk 'NR == 1 { print $1 }' "${checksum_path}")"
    require_sha256_value "${expected_hash}" "ZIP checksum"
    [ "${actual_hash}" = "${expected_hash}" ] \
      || die "SHA-256 does not match ${checksum_path}"
    echo "verified checksum file: ${checksum_path}"
  else
    echo "warning: checksum file is absent: ${checksum_path}" >&2
  fi
  echo "verified ZIP SHA-256: ${actual_hash}"
}

SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CODE_ROOT="$(CDPATH= cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
PROJECT_PATH="${CODE_ROOT}/Inflow.xcodeproj"
VERIFY_LAUNCH="${SCRIPT_DIRECTORY}/verify-launch.sh"
VERIFY_ARCHIVE="${SCRIPT_DIRECTORY}/verify-release-archive.sh"
DEFAULT_OUTPUT_ROOT="${CODE_ROOT}/build/releases"
REPOSITORY_ROOT="$(CDPATH= cd -- "${CODE_ROOT}/.." && pwd)"
RELEASE_EVIDENCE_SCHEMA="${CODE_ROOT}/quality/release-evidence-schema.json"
RELEASE_TRUST_ROOT="${CODE_ROOT}/quality/release-trust-root.json"

VERIFICATION_EVIDENCE_KEYS='analyze_passed,analyze_xcresult_sha256,app_binary_sha256,app_build_version,app_bundle_id,app_cdhash,app_entitlements_sha256,app_info_plist_sha256,app_marketing_version,app_privacy_manifest_sha256,app_release_profile,app_signing_authority,app_signing_certificate_sha256,app_signing_certificate_subject_rfc2253,app_source_head,app_team_id,archive_verified,archive_zip_sha256,authoritative_target_performance_complete,cargo_lock_sha256,cargo_toml_sha256,created_at_utc,debug_xcresult_sha256,dirty,evidence_kind,macos_failed_test_count,macos_skipped_test_count,macos_test_count,macos_tests_passed,manual_update_url_sha256,mode,performance_manifest_sha256,performance_xcresult_sha256,project_file_sha256,release_workflow_script_sha256,repository_performance_failed_test_count,repository_performance_skipped_test_count,repository_performance_smoke_passed,repository_performance_test_count,rust,rust_clippy_log_sha256,rust_clippy_passed,rust_format_log_sha256,rust_format_passed,rust_test_count,rust_test_log_sha256,rust_tests_passed,rust_toolchain_sha256,schema_version,source_head,status,verification_signer_sha256,verify_archive_script_sha256,verify_launch_script_sha256,xcode'
VERIFICATION_APP_FIELD_KEYS='app_binary_sha256,app_build_version,app_bundle_id,app_cdhash,app_entitlements_sha256,app_info_plist_sha256,app_marketing_version,app_privacy_manifest_sha256,app_release_profile,app_signing_authority,app_signing_certificate_sha256,app_signing_certificate_subject_rfc2253,app_source_head,app_team_id,manual_update_url_sha256'
PRODUCT_BASELINE_EVIDENCE_KEYS='approved_at_utc,approver_id,baseline_id,document_set_sha256,schema_version,source_head,status'
PERFORMANCE_EVIDENCE_KEYS='aggregate_cpu_window_percent,aggregate_rss_peak_bytes,architecture,authoritative_latency_samples_complete,blank_window_maximum_milliseconds,blank_window_median_milliseconds,cold_inflow_exited,cold_minimum_not_running_seconds,cold_open_maximum_milliseconds,cold_open_median_milliseconds,cold_start_event,continuous_input_duration_seconds,device_restarted,dirty,full_fixture_sha256,full_fixture_status,image_corpus_sha256,image_count,image_total_bytes,input_pause_maximum_milliseconds,input_pause_p95_milliseconds,latency_sample_count,macos_build,macos_version,manifest_sha256,measured_runs,model_identifier,other_foreground_apps_closed,physical_memory_bytes,post_restart_wait_seconds,preview_update_p95_milliseconds,process_tree_complete,process_tree_sha256,raw_samples_sha256,resource_sample_window_seconds,schema_version,source_head,statistics_complete,statistics_sha256,status,structure_fixture_sha256,text_fixture_bytes,text_fixture_lines,text_fixture_sha256,view_switch_maximum_milliseconds,warm_idle_seconds,warm_inflow_state,warm_open_median_milliseconds,warm_open_p95_milliseconds,warm_start_event,warmup_runs'
RELEASE_MANIFEST_KEYS='app_binary_sha256,app_cdhash,app_info_plist_sha256,archive_zip_sha256,build_version,bundle_id,channel,created_at_utc,dirty,distribution_profile,distribution_zip_sha256,manual_update_origin,marketing_version,notarization_ticket_stapled,performance_evidence_sha256,performance_evidence_signature_sha256,performance_evidence_signer_sha256,performance_full_fixture_sha256,performance_manifest_sha256,performance_process_tree_sha256,performance_raw_samples_sha256,performance_statistics_sha256,previous_manifest_sha256,previous_manifest_signature_sha256,previous_release_sequence,product_approved_at_utc,product_approver_id,product_baseline_evidence_sha256,product_baseline_id,product_baseline_signature_sha256,product_baseline_signer_sha256,product_document_set_sha256,release_evidence_schema_sha256,release_sequence,schema_version,signing_authority,signing_certificate_sha256,signing_certificate_subject_rfc2253,source_head,team_id,update_mode,verification_evidence_sha256,verification_evidence_signature_sha256,verification_evidence_signer_sha256'
RELEASE_TRUST_ROOT_KEYS='bundle_id,channel,distribution_profile,minimum_release_sequence,reason,schema_version,signing_certificate_sha256,status,team_id'

require_clean_repository() {
  [ -z "$(/usr/bin/git -C "${REPOSITORY_ROOT}" status --porcelain)" ] \
    || die "retained and distributable candidates require a clean worktree"
}

sha256() {
  hash_path="$1"
  [ -f "${hash_path}" ] && [ ! -L "${hash_path}" ] \
    || die "SHA-256 input must be a regular non-symlink file: ${hash_path}"
  hash_output="$(/usr/bin/shasum -a 256 -- "${hash_path}")" \
    || die "could not compute SHA-256: ${hash_path}"
  hash_value="${hash_output%%[[:space:]]*}"
  require_sha256_value "${hash_value}" "SHA-256 for ${hash_path}"
  echo "${hash_value}" | /usr/bin/tr '[:upper:]' '[:lower:]'
}

require_absolute_regular_file() {
  candidate_path="$1"
  label="$2"
  case "${candidate_path}" in
    /*) ;;
    *) die "${label} must be an absolute path" ;;
  esac
  [ -f "${candidate_path}" ] && [ ! -L "${candidate_path}" ] \
    || die "${label} must be a regular non-symlink file: ${candidate_path}"
}

snapshot_regular_file() {
  snapshot_source="$1"
  snapshot_destination="$2"
  snapshot_label="$3"
  require_absolute_regular_file "${snapshot_source}" "${snapshot_label}"
  [ ! -e "${snapshot_destination}" ] \
    || die "refusing to replace staged ${snapshot_label}"
  /bin/cp -p "${snapshot_source}" "${snapshot_destination}" \
    || die "could not snapshot ${snapshot_label}"
  require_absolute_regular_file "${snapshot_destination}" "staged ${snapshot_label}"
}

plist_value() {
  /usr/bin/plutil -extract "$2" raw "$1" 2>/dev/null \
    || die "missing required evidence field '$2' in $1"
}

require_sha256_value() {
  value="$1"
  label="$2"
  echo "${value}" | /usr/bin/grep -Eq '^[0-9A-Fa-f]{64}$' \
    || die "${label} must be a 64-character SHA-256 value"
}

require_nonempty_evidence_value() {
  evidence_path="$1"
  key="$2"
  value="$(plist_value "${evidence_path}" "${key}")"
  [ -n "${value}" ] || die "evidence field '${key}' must not be empty"
  echo "${value}"
}

require_exact_flat_keys() {
  evidence_path="$1"
  expected_csv="$2"
  actual_keys="$({
    /usr/bin/plutil -convert xml1 -o - "${evidence_path}" \
      | /usr/bin/sed -n 's/^[[:space:]]*<key>\([^<]*\)<\/key>$/\1/p'
  } | LC_ALL=C /usr/bin/sort | /usr/bin/tr '\n' ',')"
  expected_keys="$(printf '%s' "${expected_csv}" | /usr/bin/tr ',' '\n' \
    | LC_ALL=C /usr/bin/sort | /usr/bin/tr '\n' ',')"
  [ "${actual_keys}" = "${expected_keys}" ] \
    || die "evidence keys do not match the closed-world schema"
}

require_plist_type() {
  evidence_path="$1"
  key="$2"
  expected_tag="$3"
  /usr/bin/plutil -extract "${key}" xml1 -o - "${evidence_path}" 2>/dev/null \
    | /usr/bin/grep -Eq "<${expected_tag}([ />])" \
    || die "evidence field '${key}' has the wrong machine type"
}

require_plist_number_type() {
  evidence_path="$1"
  key="$2"
  /usr/bin/plutil -extract "${key}" xml1 -o - "${evidence_path}" 2>/dev/null \
    | /usr/bin/grep -Eq '<(integer|real)>' \
    || die "evidence field '${key}' is not a machine number"
}

hash_string() {
  string_hash="$(printf '%s' "$1" | /usr/bin/shasum -a 256 \
    | /usr/bin/awk 'NF == 2 { print $1; exit }')"
  require_sha256_value "${string_hash}" "string SHA-256"
  echo "${string_hash}"
}

verify_pinned_evidence_signature() (
  evidence_path="$1"
  signature_path="$2"
  expected_signer_sha256="$3"
  pinned_evidence_label="$4"

  require_command openssl
  [ -f "${evidence_path}" ] \
    || die "${pinned_evidence_label} evidence does not exist: ${evidence_path}"
  [ -f "${signature_path}" ] \
    || die "${pinned_evidence_label} CMS signature does not exist: ${signature_path}"
  require_sha256_value \
    "${expected_signer_sha256}" "${pinned_evidence_label} trusted signer fingerprint"

  verification_directory="$(/usr/bin/mktemp -d -t inflow-evidence-signature)"
  case "${verification_directory}" in
    /private/tmp/* | /private/var/* | /tmp/* | /var/*) ;;
    *) die "refusing unexpected evidence verification path: ${verification_directory}" ;;
  esac
  /bin/chmod 700 "${verification_directory}"
  trap '/bin/rm -rf -- "${verification_directory}"' EXIT
  trap '/bin/rm -rf -- "${verification_directory}"; exit 129' HUP
  trap '/bin/rm -rf -- "${verification_directory}"; exit 130' INT
  trap '/bin/rm -rf -- "${verification_directory}"; exit 143' TERM
  signer_certificate="${verification_directory}/signer.pem"
  extract_single_cms_signer_certificate \
    "${evidence_path}" "${signature_path}" "${signer_certificate}" \
    "${pinned_evidence_label}"
  if ! /usr/bin/openssl x509 -in "${signer_certificate}" -checkend 0 -noout \
      >/dev/null 2>&1
  then
    /bin/rm -rf -- "${verification_directory}"
    die "${pinned_evidence_label} signer certificate is expired or invalid"
  fi
  actual_signer_sha256="$(
    /usr/bin/openssl x509 -in "${signer_certificate}" -outform DER \
      | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
  )"
  expected_signer_sha256="$(
    echo "${expected_signer_sha256}" | /usr/bin/tr '[:upper:]' '[:lower:]'
  )"
  [ "${actual_signer_sha256}" = "${expected_signer_sha256}" ] \
    || die "${pinned_evidence_label} signer certificate does not match the protected fingerprint"
  echo "${actual_signer_sha256}"
)

certificate_subject_rfc2253() {
  cert_subject_path="$1"
  /usr/bin/openssl x509 -in "${cert_subject_path}" -noout \
    -subject -nameopt RFC2253 \
    | /usr/bin/sed -E 's/^subject=[[:space:]]*//'
}

certificate_team_id() {
  cert_team_path="$1"
  cert_subject="$(certificate_subject_rfc2253 "${cert_team_path}")"
  cert_team_id_value="$(
    echo "${cert_subject}" | /usr/bin/tr ',' '\n' \
      | /usr/bin/awk '
          {
            component = $0
            sub(/^subject=/, "", component)
            if (component ~ /^OU=/) {
              sub(/^OU=/, "", component)
              print component
              exit
            }
          }
        '
  )"
  [ -n "${cert_team_id_value}" ] || die "CMS signer certificate does not contain a Team ID (OU)"
  case "${cert_team_id_value}" in
    *[!A-Za-z0-9]* | '') die "CMS signer certificate contains an invalid Team ID" ;;
  esac
  echo "${cert_team_id_value}"
}

certificate_sha256() {
  cert_hash_path="$1"
  /usr/bin/openssl x509 -in "${cert_hash_path}" -outform DER \
    | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
}

extract_single_cms_signer_certificate() {
  content_path="$1"
  signature_path="$2"
  signer_certificate="$3"
  cms_signer_label="$4"
  if ! /usr/bin/openssl cms -verify -binary -inform DER \
      -in "${signature_path}" -content "${content_path}" -noverify \
      -signer "${signer_certificate}" -out /dev/null >/dev/null 2>&1
  then
    die "${cms_signer_label} detached CMS signature is invalid"
  fi
  signer_count="$({
    /usr/bin/grep -c '^-----BEGIN CERTIFICATE-----$' "${signer_certificate}" || true
  })"
  [ "${signer_count}" = "1" ] \
    || die "${cms_signer_label} CMS must contain exactly one signer"
}

verify_release_manifest_identity_contract() (
  manifest_path="$1"
  signature_path="$2"
  expected_sequence="$3"
  expected_team_id="$4"
  expected_bundle_id="$5"
  expected_signer_sha256="$6"

  require_sha256_value "${expected_signer_sha256}" "expected release signer fingerprint"
  identity_directory="$(/usr/bin/mktemp -d -t inflow-release-identity)"
  case "${identity_directory}" in
    /private/tmp/* | /private/var/* | /tmp/* | /var/*) ;;
    *) die "refusing unexpected release identity path: ${identity_directory}" ;;
  esac
  /bin/chmod 700 "${identity_directory}"
  trap '/bin/rm -rf -- "${identity_directory}"' EXIT
  trap '/bin/rm -rf -- "${identity_directory}"; exit 129' HUP
  trap '/bin/rm -rf -- "${identity_directory}"; exit 130' INT
  trap '/bin/rm -rf -- "${identity_directory}"; exit 143' TERM
  signer_certificate="${identity_directory}/signer.pem"
  extract_single_cms_signer_certificate \
    "${manifest_path}" "${signature_path}" "${signer_certificate}" \
    "release manifest"
  verify_release_manifest_identity_with_signer \
    "${manifest_path}" "${signer_certificate}" \
    "${expected_sequence}" "${expected_team_id}" "${expected_bundle_id}" \
    "${expected_signer_sha256}"
)

verify_release_manifest_identity_with_signer() {
  manifest_path="$1"
  signer_certificate="$2"
  expected_sequence="$3"
  expected_team_id="$4"
  expected_bundle_id="$5"
  expected_signer_sha256="$6"

  require_sha256_value "${expected_signer_sha256}" "expected release signer fingerprint"
  actual_signer_sha256="$(certificate_sha256 "${signer_certificate}")"
  actual_signer_subject="$(certificate_subject_rfc2253 "${signer_certificate}")"
  actual_signer_team_id="$(certificate_team_id "${signer_certificate}")"

  declared_signer_sha256="$(plist_value "${manifest_path}" signing_certificate_sha256)"
  declared_signer_subject="$(plist_value "${manifest_path}" signing_certificate_subject_rfc2253)"
  declared_team_id="$(plist_value "${manifest_path}" team_id)"
  declared_bundle_id="$(plist_value "${manifest_path}" bundle_id)"
  [ "$(plist_value "${manifest_path}" schema_version)" = "2" ] \
    || die "unsupported release manifest identity schema"
  require_sha256_value "${declared_signer_sha256}" "declared release signer fingerprint"
  [ "${actual_signer_sha256}" = "${declared_signer_sha256}" ] \
    || die "release manifest signer certificate does not match its declared fingerprint"
  [ "${actual_signer_subject}" = "${declared_signer_subject}" ] \
    || die "release manifest signer certificate does not match its declared subject"
  [ "${actual_signer_team_id}" = "${declared_team_id}" ] \
    || die "release manifest signer Team ID does not match its declared Team ID"
  [ "${actual_signer_sha256}" = "${expected_signer_sha256}" ] \
    || die "predecessor signer certificate does not match the current notarized app"
  [ "${actual_signer_team_id}" = "${expected_team_id}" ] \
    || die "predecessor signer Team ID does not match the current notarized app"
  [ "${declared_bundle_id}" = "${expected_bundle_id}" ] \
    || die "predecessor bundle ID does not match the current notarized app"
  [ "$(plist_value "${manifest_path}" release_sequence)" = "${expected_sequence}" ] \
    || die "predecessor manifest has the wrong release sequence"
  [ "$(plist_value "${manifest_path}" channel)" = "stable-direct" ] \
    || die "predecessor manifest belongs to a different release channel"
  [ "$(plist_value "${manifest_path}" distribution_profile)" = "developer-id-notarized-zip" ] \
    || die "predecessor manifest has a different distribution profile"
}

extract_app_signer_identity() {
  app_path="$1"
  identity_directory="$(/usr/bin/mktemp -d -t inflow-app-identity)"
  case "${identity_directory}" in
    /private/tmp/* | /private/var/* | /tmp/* | /var/*) ;;
    *) die "refusing unexpected app identity path: ${identity_directory}" ;;
  esac
  certificate_prefix="${identity_directory}/codesign"
  if ! /usr/bin/codesign -d --extract-certificates="${certificate_prefix}" \
      "${app_path}" >/dev/null 2>&1
  then
    /bin/rm -rf -- "${identity_directory}"
    die "could not extract the notarized app signing certificate"
  fi
  [ -f "${certificate_prefix}0" ] || {
    /bin/rm -rf -- "${identity_directory}"
    die "notarized app signing certificate is missing"
  }
  signer_certificate="${identity_directory}/signer.pem"
  if ! /usr/bin/openssl x509 -inform DER -in "${certificate_prefix}0" \
      -out "${signer_certificate}" >/dev/null 2>&1
  then
    /bin/rm -rf -- "${identity_directory}"
    die "notarized app signing certificate could not be decoded"
  fi
  APP_SIGNER_SHA256="$(certificate_sha256 "${signer_certificate}")"
  APP_SIGNER_SUBJECT_RFC2253="$(certificate_subject_rfc2253 "${signer_certificate}")"
  APP_SIGNER_TEAM_ID="$(certificate_team_id "${signer_certificate}")"
  /bin/rm -rf -- "${identity_directory}"
}

write_expected_app_fields() {
  app_path="$1"
  output_path="$2"
  info_path="${app_path}/Contents/Info.plist"
  binary_path="${app_path}/Contents/MacOS/Inflow"
  privacy_path="${app_path}/Contents/Resources/PrivacyInfo.xcprivacy"
  for required_path in "${info_path}" "${binary_path}" "${privacy_path}"; do
    require_absolute_regular_file "${required_path}" "signed App artifact"
  done
  [ ! -e "${output_path}" ] || die "refusing to replace App field contract"

  signature="$(signature_details "${app_path}")"
  app_cdhash="$(echo "${signature}" | /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }')"
  app_authority="$(echo "${signature}" | /usr/bin/awk -F= '$1 == "Authority" { print $2; exit }')"
  app_team_id="$(echo "${signature}" | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
  [ -n "${app_cdhash}" ] && [ -n "${app_authority}" ] && [ -n "${app_team_id}" ] \
    || die "signed App identity fields are incomplete"
  extract_app_signer_identity "${app_path}"

  entitlements_path="${output_path}.entitlements.plist"
  /usr/bin/codesign -d --entitlements :- "${app_path}" \
    >"${entitlements_path}" 2>/dev/null \
    || die "could not read signed App entitlements"

  /usr/bin/plutil -create xml1 "${output_path}"
  /usr/bin/plutil -insert app_source_head -string \
    "$(plist_value "${info_path}" InflowSourceHead)" "${output_path}"
  /usr/bin/plutil -insert app_bundle_id -string \
    "$(plist_value "${info_path}" CFBundleIdentifier)" "${output_path}"
  /usr/bin/plutil -insert app_marketing_version -string \
    "$(plist_value "${info_path}" CFBundleShortVersionString)" "${output_path}"
  /usr/bin/plutil -insert app_build_version -string \
    "$(plist_value "${info_path}" CFBundleVersion)" "${output_path}"
  /usr/bin/plutil -insert app_release_profile -string \
    "$(plist_value "${info_path}" InflowReleaseProfile)" "${output_path}"
  /usr/bin/plutil -insert manual_update_url_sha256 -string \
    "$(hash_string "$(plist_value "${info_path}" InflowManualUpdateURL)")" "${output_path}"
  /usr/bin/plutil -insert app_info_plist_sha256 -string "$(sha256 "${info_path}")" "${output_path}"
  /usr/bin/plutil -insert app_binary_sha256 -string "$(sha256 "${binary_path}")" "${output_path}"
  /usr/bin/plutil -insert app_cdhash -string "${app_cdhash}" "${output_path}"
  /usr/bin/plutil -insert app_team_id -string "${app_team_id}" "${output_path}"
  /usr/bin/plutil -insert app_signing_authority -string "${app_authority}" "${output_path}"
  /usr/bin/plutil -insert app_signing_certificate_sha256 -string \
    "${APP_SIGNER_SHA256}" "${output_path}"
  /usr/bin/plutil -insert app_signing_certificate_subject_rfc2253 -string \
    "${APP_SIGNER_SUBJECT_RFC2253}" "${output_path}"
  /usr/bin/plutil -insert app_entitlements_sha256 -string \
    "$(sha256 "${entitlements_path}")" "${output_path}"
  /usr/bin/plutil -insert app_privacy_manifest_sha256 -string \
    "$(sha256 "${privacy_path}")" "${output_path}"
  /usr/bin/plutil -convert json "${output_path}"
  /bin/rm -f -- "${entitlements_path}"
}

verify_verification_app_fields() {
  verification_fields_evidence="$1"
  expected_fields_path="$2"
  require_absolute_regular_file "${expected_fields_path}" "expected App field contract"
  require_exact_flat_keys "${expected_fields_path}" "${VERIFICATION_APP_FIELD_KEYS}"
  remaining_fields="${VERIFICATION_APP_FIELD_KEYS}"
  while [ -n "${remaining_fields}" ]; do
    field="${remaining_fields%%,*}"
    if [ "${remaining_fields}" = "${field}" ]; then
      remaining_fields=""
    else
      remaining_fields="${remaining_fields#*,}"
    fi
    [ "$(plist_value "${verification_fields_evidence}" "${field}")" \
        = "$(plist_value "${expected_fields_path}" "${field}")" ] \
      || die "verification evidence does not match App field '${field}'"
  done
}

verify_bound_release_artifacts() {
  manifest_path="$1"
  distribution_zip="$2"
  archive_zip="$3"
  [ -f "${distribution_zip}" ] || die "distribution ZIP does not exist: ${distribution_zip}"
  [ -f "${archive_zip}" ] || die "archive ZIP does not exist: ${archive_zip}"
  expected_distribution="$(plist_value "${manifest_path}" distribution_zip_sha256)"
  expected_archive="$(plist_value "${manifest_path}" archive_zip_sha256)"
  require_sha256_value "${expected_distribution}" "release distribution ZIP hash"
  require_sha256_value "${expected_archive}" "release Archive ZIP hash"
  [ "$(sha256 "${distribution_zip}")" = "${expected_distribution}" ] \
    || die "distribution ZIP does not match the release manifest"
  [ "$(sha256 "${archive_zip}")" = "${expected_archive}" ] \
    || die "archive ZIP does not match the release manifest"
}

verify_release_manifest_contract() {
  release_manifest_path="$1"
  minimum_release_sequence="$2"
  require_absolute_regular_file "${release_manifest_path}" "release manifest"
  require_exact_flat_keys "${release_manifest_path}" "${RELEASE_MANIFEST_KEYS}"
  for release_integer_field in \
    schema_version release_sequence previous_release_sequence
  do
    require_plist_type "${release_manifest_path}" "${release_integer_field}" integer
  done
  for release_boolean_field in dirty notarization_ticket_stapled; do
    release_boolean_value="$(
      plist_value "${release_manifest_path}" "${release_boolean_field}"
    )"
    case "${release_boolean_value}" in
      true) require_plist_type "${release_manifest_path}" "${release_boolean_field}" true ;;
      false) require_plist_type "${release_manifest_path}" "${release_boolean_field}" false ;;
      *) die "invalid release manifest boolean '${release_boolean_field}'" ;;
    esac
  done
  release_string_fields="$(
    printf '%s' "${RELEASE_MANIFEST_KEYS}" \
      | /usr/bin/tr ',' '\n' \
      | /usr/bin/grep -Ev '^(schema_version|release_sequence|previous_release_sequence|dirty|notarization_ticket_stapled)$'
  )"
  while IFS= read -r release_string_field; do
    [ -n "${release_string_field}" ] || continue
    require_plist_type "${release_manifest_path}" "${release_string_field}" string
  done <<EOF
${release_string_fields}
EOF

  [ "$(plist_value "${release_manifest_path}" schema_version)" = "2" ] \
    || die "unsupported release manifest schema"
  [ "$(plist_value "${release_manifest_path}" dirty)" = "false" ] \
    || die "release manifest declares a dirty source"
  [ "$(plist_value "${release_manifest_path}" notarization_ticket_stapled)" = "true" ] \
    || die "release manifest does not declare a stapled notarization ticket"
  [ "$(plist_value "${release_manifest_path}" channel)" = "stable-direct" ] \
    || die "release manifest belongs to an unsupported channel"
  [ "$(plist_value "${release_manifest_path}" distribution_profile)" = "developer-id-notarized-zip" ] \
    || die "release manifest belongs to an unsupported distribution profile"
  [ "$(plist_value "${release_manifest_path}" update_mode)" = "manual-check" ] \
    || die "release manifest has an unsupported update mode"
  echo "$(plist_value "${release_manifest_path}" source_head)" \
    | /usr/bin/grep -Eq '^[0-9a-f]{40}([0-9a-f]{24})?$' \
    || die "release manifest source HEAD is invalid"
  echo "$(plist_value "${release_manifest_path}" app_cdhash)" \
    | /usr/bin/grep -Eq '^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$' \
    || die "release manifest App CodeDirectory hash is invalid"
  echo "$(plist_value "${release_manifest_path}" created_at_utc)" \
    | /usr/bin/grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || die "release manifest creation time is invalid"
  echo "$(plist_value "${release_manifest_path}" product_approved_at_utc)" \
    | /usr/bin/grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || die "release manifest product approval time is invalid"

  release_sequence_value="$(plist_value "${release_manifest_path}" release_sequence)"
  previous_release_sequence_value="$(
    plist_value "${release_manifest_path}" previous_release_sequence
  )"
  case "${release_sequence_value}:${minimum_release_sequence}" in
    *[!0-9:]* | 0:* | *:) die "release sequence or trusted minimum is invalid" ;;
  esac
  [ "${release_sequence_value}" -ge "${minimum_release_sequence}" ] \
    || die "release sequence is below the independently published trusted minimum"
  if [ "${release_sequence_value}" -eq 1 ]; then
    [ "${previous_release_sequence_value}" -eq 0 ] \
      && [ "$(plist_value "${release_manifest_path}" previous_manifest_sha256)" = "none" ] \
      && [ "$(plist_value "${release_manifest_path}" previous_manifest_signature_sha256)" = "none" ] \
      || die "release sequence 1 has an invalid predecessor contract"
  else
    [ "${previous_release_sequence_value}" -eq $((release_sequence_value - 1)) ] \
      || die "release manifest predecessor sequence is not adjacent"
    require_sha256_value \
      "$(plist_value "${release_manifest_path}" previous_manifest_sha256)" \
      "previous release manifest hash"
    require_sha256_value \
      "$(plist_value "${release_manifest_path}" previous_manifest_signature_sha256)" \
      "previous release signature hash"
  fi

  release_hash_fields='app_binary_sha256,app_info_plist_sha256,archive_zip_sha256,distribution_zip_sha256,performance_evidence_sha256,performance_evidence_signature_sha256,performance_evidence_signer_sha256,performance_full_fixture_sha256,performance_manifest_sha256,performance_process_tree_sha256,performance_raw_samples_sha256,performance_statistics_sha256,product_baseline_evidence_sha256,product_baseline_signature_sha256,product_baseline_signer_sha256,product_document_set_sha256,release_evidence_schema_sha256,signing_certificate_sha256,verification_evidence_sha256,verification_evidence_signature_sha256,verification_evidence_signer_sha256'
  remaining_release_hash_fields="${release_hash_fields}"
  while [ -n "${remaining_release_hash_fields}" ]; do
    release_hash_field="${remaining_release_hash_fields%%,*}"
    if [ "${remaining_release_hash_fields}" = "${release_hash_field}" ]; then
      remaining_release_hash_fields=""
    else
      remaining_release_hash_fields="${remaining_release_hash_fields#*,}"
    fi
    require_sha256_value \
      "$(plist_value "${release_manifest_path}" "${release_hash_field}")" \
      "release manifest field ${release_hash_field}"
  done
  [ "$(plist_value "${release_manifest_path}" release_evidence_schema_sha256)" \
      = "$(sha256 "${RELEASE_EVIDENCE_SCHEMA}")" ] \
    || die "release manifest does not bind the current evidence schema"
}

load_approved_release_trust_root() {
  require_absolute_regular_file "${RELEASE_TRUST_ROOT}" "release trust root"
  require_exact_flat_keys "${RELEASE_TRUST_ROOT}" "${RELEASE_TRUST_ROOT_KEYS}"
  require_plist_type "${RELEASE_TRUST_ROOT}" schema_version integer
  [ "$(plist_value "${RELEASE_TRUST_ROOT}" schema_version)" = "1" ] \
    || die "unsupported release trust-root schema"
  [ "$(plist_value "${RELEASE_TRUST_ROOT}" status)" = "approved" ] \
    || die "public release trust root is not approved; verification fails closed"
  for release_trust_string_field in \
    status channel distribution_profile bundle_id team_id \
    signing_certificate_sha256 reason
  do
    require_plist_type \
      "${RELEASE_TRUST_ROOT}" "${release_trust_string_field}" string
  done
  require_plist_type \
    "${RELEASE_TRUST_ROOT}" minimum_release_sequence integer
  [ "$(plist_value "${RELEASE_TRUST_ROOT}" channel)" = "stable-direct" ] \
    && [ "$(plist_value "${RELEASE_TRUST_ROOT}" distribution_profile)" \
      = "developer-id-notarized-zip" ] \
    || die "release trust root authorizes a different channel or profile"
  RELEASE_TRUST_BUNDLE_ID="$(plist_value "${RELEASE_TRUST_ROOT}" bundle_id)"
  RELEASE_TRUST_TEAM_ID="$(plist_value "${RELEASE_TRUST_ROOT}" team_id)"
  RELEASE_TRUST_SIGNER_SHA256="$(
    plist_value "${RELEASE_TRUST_ROOT}" signing_certificate_sha256
  )"
  RELEASE_TRUST_MINIMUM_SEQUENCE="$(
    plist_value "${RELEASE_TRUST_ROOT}" minimum_release_sequence
  )"
  [ "${RELEASE_TRUST_BUNDLE_ID}" = "com.inflow.desktop" ] \
    || die "release trust root authorizes an unexpected bundle ID"
  case "${RELEASE_TRUST_TEAM_ID}" in
    *[!A-Za-z0-9]* | '') die "release trust root has an invalid Team ID" ;;
  esac
  require_sha256_value \
    "${RELEASE_TRUST_SIGNER_SHA256}" "release trust-root signer fingerprint"
  case "${RELEASE_TRUST_MINIMUM_SEQUENCE}" in
    *[!0-9]* | '' | 0) die "release trust root has no valid minimum sequence" ;;
  esac
}

verify_verification_contract() {
  evidence_path="$1"
  expected_head="$2"
  archive_zip="$3"
  expected_app_fields="$4"

  require_absolute_regular_file "${evidence_path}" "verification evidence"
  require_exact_flat_keys "${evidence_path}" "${VERIFICATION_EVIDENCE_KEYS}"
  require_absolute_regular_file "${archive_zip}" "verification Archive ZIP"
  verify_zip "${archive_zip}" >/dev/null

  for integer_field in \
    schema_version rust_test_count macos_test_count macos_failed_test_count \
    macos_skipped_test_count repository_performance_test_count \
    repository_performance_failed_test_count repository_performance_skipped_test_count
  do
    require_plist_type "${evidence_path}" "${integer_field}" integer
  done
  for boolean_field in \
    dirty rust_format_passed rust_clippy_passed rust_tests_passed macos_tests_passed \
    analyze_passed repository_performance_smoke_passed \
    authoritative_target_performance_complete archive_verified
  do
    boolean_value="$(plist_value "${evidence_path}" "${boolean_field}")"
    case "${boolean_value}" in true) require_plist_type "${evidence_path}" "${boolean_field}" true ;; false) require_plist_type "${evidence_path}" "${boolean_field}" false ;; *) die "invalid boolean evidence field '${boolean_field}'" ;; esac
  done

  [ "$(plist_value "${evidence_path}" schema_version)" = "1" ] \
    || die "unsupported verification evidence schema"
  [ "$(plist_value "${evidence_path}" evidence_kind)" = "inflow-launch-verification" ] \
    || die "unexpected verification evidence kind"
  [ "$(plist_value "${evidence_path}" status)" = "passed" ] \
    || die "repository verification did not pass"
  [ "$(plist_value "${evidence_path}" source_head)" = "${expected_head}" ] \
    || die "verification evidence does not bind source HEAD ${expected_head}"
  [ "$(plist_value "${evidence_path}" app_source_head)" = "${expected_head}" ] \
    || die "verified App was not built from source HEAD ${expected_head}"
  [ "$(plist_value "${evidence_path}" dirty)" = "false" ] \
    || die "verification evidence was produced from a dirty worktree"
  [ "$(plist_value "${evidence_path}" mode)" = "signed" ] \
    || die "verification evidence is not from the signed Archive gate"
  echo "$(plist_value "${evidence_path}" created_at_utc)" \
    | /usr/bin/grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || die "verification evidence creation time is invalid"
  require_nonempty_evidence_value "${evidence_path}" xcode >/dev/null
  require_nonempty_evidence_value "${evidence_path}" rust >/dev/null

  [ "$(plist_value "${evidence_path}" rust_format_passed)" = "true" ] \
    && [ "$(plist_value "${evidence_path}" rust_clippy_passed)" = "true" ] \
    && [ "$(plist_value "${evidence_path}" rust_tests_passed)" = "true" ] \
    || die "Rust verification fields are incomplete"
  [ "$(plist_value "${evidence_path}" rust_test_count)" -ge 150 ] \
    || die "Rust test count is below the reviewed baseline"
  [ "$(plist_value "${evidence_path}" macos_tests_passed)" = "true" ] \
    && [ "$(plist_value "${evidence_path}" macos_test_count)" -ge 300 ] \
    && [ "$(plist_value "${evidence_path}" macos_failed_test_count)" = "0" ] \
    && [ "$(plist_value "${evidence_path}" macos_skipped_test_count)" = "0" ] \
    || die "macOS full-suite evidence is incomplete or below baseline"
  [ "$(plist_value "${evidence_path}" analyze_passed)" = "true" ] \
    || die "Analyze evidence is incomplete"
  [ "$(plist_value "${evidence_path}" repository_performance_smoke_passed)" = "true" ] \
    && [ "$(plist_value "${evidence_path}" repository_performance_test_count)" = "1" ] \
    && [ "$(plist_value "${evidence_path}" repository_performance_failed_test_count)" = "0" ] \
    && [ "$(plist_value "${evidence_path}" repository_performance_skipped_test_count)" = "0" ] \
    || die "repository performance smoke evidence is incomplete"
  [ "$(plist_value "${evidence_path}" authoritative_target_performance_complete)" = "false" ] \
    || die "repository verification must not impersonate authoritative target evidence"
  [ "$(plist_value "${evidence_path}" archive_verified)" = "true" ] \
    || die "Archive verification is incomplete"
  [ "$(plist_value "${evidence_path}" archive_zip_sha256)" = "$(sha256 "${archive_zip}")" ] \
    || die "verification evidence belongs to a different Archive ZIP"

  hash_fields='rust_format_log_sha256,rust_clippy_log_sha256,rust_test_log_sha256,debug_xcresult_sha256,analyze_xcresult_sha256,performance_xcresult_sha256,performance_manifest_sha256,verify_launch_script_sha256,verify_archive_script_sha256,release_workflow_script_sha256,project_file_sha256,cargo_lock_sha256,cargo_toml_sha256,rust_toolchain_sha256,archive_zip_sha256,manual_update_url_sha256,app_info_plist_sha256,app_binary_sha256,app_signing_certificate_sha256,app_entitlements_sha256,app_privacy_manifest_sha256,verification_signer_sha256'
  remaining_hash_fields="${hash_fields}"
  while [ -n "${remaining_hash_fields}" ]; do
    hash_field="${remaining_hash_fields%%,*}"
    if [ "${remaining_hash_fields}" = "${hash_field}" ]; then
      remaining_hash_fields=""
    else
      remaining_hash_fields="${remaining_hash_fields#*,}"
    fi
    require_sha256_value "$(plist_value "${evidence_path}" "${hash_field}")" \
      "verification field ${hash_field}"
  done
  echo "$(plist_value "${evidence_path}" source_head)" \
    | /usr/bin/grep -Eq '^[0-9a-f]{40}([0-9a-f]{24})?$' \
    || die "verification source HEAD is not a Git object ID"
  echo "$(plist_value "${evidence_path}" app_cdhash)" \
    | /usr/bin/grep -Eq '^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$' \
    || die "verified App CodeDirectory hash is invalid"

  [ "$(plist_value "${evidence_path}" performance_manifest_sha256)" \
      = "$(sha256 "${CODE_ROOT}/quality/performance-manifest.json")" ] \
    || die "verification evidence does not bind the current performance manifest"
  [ "$(plist_value "${evidence_path}" verify_launch_script_sha256)" \
      = "$(sha256 "${VERIFY_LAUNCH}")" ] \
    || die "verification evidence does not bind the current launch gate"
  [ "$(plist_value "${evidence_path}" verify_archive_script_sha256)" \
      = "$(sha256 "${VERIFY_ARCHIVE}")" ] \
    || die "verification evidence does not bind the current Archive gate"
  [ "$(plist_value "${evidence_path}" release_workflow_script_sha256)" \
      = "$(sha256 "$0")" ] \
    || die "verification evidence does not bind the current release workflow"
  [ "$(plist_value "${evidence_path}" project_file_sha256)" \
      = "$(sha256 "${PROJECT_PATH}/project.pbxproj")" ] \
    || die "verification evidence does not bind the current Xcode project"
  [ "$(plist_value "${evidence_path}" cargo_lock_sha256)" \
      = "$(sha256 "${CODE_ROOT}/core/Cargo.lock")" ] \
    || die "verification evidence does not bind Cargo.lock"
  [ "$(plist_value "${evidence_path}" cargo_toml_sha256)" \
      = "$(sha256 "${CODE_ROOT}/core/Cargo.toml")" ] \
    || die "verification evidence does not bind Cargo.toml"
  [ "$(plist_value "${evidence_path}" rust_toolchain_sha256)" \
      = "$(sha256 "${CODE_ROOT}/rust-toolchain.toml")" ] \
    || die "verification evidence does not bind the Rust toolchain"
  verify_verification_app_fields "${evidence_path}" "${expected_app_fields}"
}

verify_verification_receipt() {
  evidence_path="$1"
  signature_path="$2"
  expected_head="$3"
  archive_zip="$4"
  expected_app_fields="$5"
  signer_pin="${INFLOW_VERIFICATION_SIGNER_SHA256:-}"
  [ -n "${signer_pin}" ] \
    || die "INFLOW_VERIFICATION_SIGNER_SHA256 must be set by protected release configuration"
  actual_signer="$({
    verify_pinned_evidence_signature \
      "${evidence_path}" "${signature_path}" "${signer_pin}" "repository verification"
  })"
  [ "$(plist_value "${evidence_path}" verification_signer_sha256)" \
      = "${actual_signer}" ] \
    || die "verification receipt does not declare its actual pinned signer"
  verify_verification_contract \
    "${evidence_path}" "${expected_head}" "${archive_zip}" "${expected_app_fields}"
}

cleanup_trusted_cms_snapshot() {
  cleanup_directory="${CMS_TRUST_DIRECTORY:-}"
  [ -n "${cleanup_directory}" ] || return 0
  CMS_TRUST_DIRECTORY=""
  case "${cleanup_directory}" in
    /private/tmp/* | /private/var/* | /tmp/* | /var/*)
      /bin/rm -rf -- "${cleanup_directory}"
      ;;
    *)
      echo "error: refusing unexpected CMS trust cleanup path: ${cleanup_directory}" >&2
      ;;
  esac
}

require_system_trusted_detached_cms() {
  content_path="$1"
  signature_path="$2"
  expected_signer_sha256="$3"
  trusted_cms_label="$4"
  require_sha256_value \
    "${expected_signer_sha256}" "${trusted_cms_label} protected signer fingerprint"
  expected_signer_sha256="$(
    echo "${expected_signer_sha256}" | /usr/bin/tr '[:upper:]' '[:lower:]'
  )"

  CMS_TRUST_DIRECTORY="$(/usr/bin/mktemp -d -t inflow-cms-trust)"
  trap 'cleanup_trusted_cms_snapshot' EXIT
  trap 'cleanup_trusted_cms_snapshot; exit 129' HUP
  trap 'cleanup_trusted_cms_snapshot; exit 130' INT
  trap 'cleanup_trusted_cms_snapshot; exit 143' TERM
  case "${CMS_TRUST_DIRECTORY}" in
    /private/tmp/* | /private/var/* | /tmp/* | /var/*) ;;
    *) die "refusing unexpected CMS trust path: ${CMS_TRUST_DIRECTORY}" ;;
  esac
  /bin/chmod 700 "${CMS_TRUST_DIRECTORY}"
  TRUSTED_CMS_CONTENT="${CMS_TRUST_DIRECTORY}/content"
  TRUSTED_CMS_SIGNATURE="${CMS_TRUST_DIRECTORY}/signature.cms"
  TRUSTED_CMS_SIGNER_CERTIFICATE="${CMS_TRUST_DIRECTORY}/signer.pem"
  snapshot_regular_file \
    "${content_path}" "${TRUSTED_CMS_CONTENT}" "${trusted_cms_label} content"
  snapshot_regular_file \
    "${signature_path}" "${TRUSTED_CMS_SIGNATURE}" \
    "${trusted_cms_label} CMS signature"
  /bin/chmod 400 "${TRUSTED_CMS_CONTENT}" "${TRUSTED_CMS_SIGNATURE}"

  extract_single_cms_signer_certificate \
    "${TRUSTED_CMS_CONTENT}" "${TRUSTED_CMS_SIGNATURE}" \
    "${TRUSTED_CMS_SIGNER_CERTIFICATE}" "${trusted_cms_label}"
  /bin/chmod 400 "${TRUSTED_CMS_SIGNER_CERTIFICATE}"
  /usr/bin/security cms -D -u 6 -c "${TRUSTED_CMS_CONTENT}" \
    -i "${TRUSTED_CMS_SIGNATURE}" -o /dev/null \
    || die "${trusted_cms_label} CMS signer does not satisfy the macOS trust policy"
  /usr/bin/security verify-cert -c "${TRUSTED_CMS_SIGNER_CERTIFICATE}" \
      -p basic -L -q >/dev/null 2>&1 \
    || die "${trusted_cms_label} CMS signer certificate chain is not trusted"
  TRUSTED_CMS_SIGNER_SHA256="$(
    certificate_sha256 "${TRUSTED_CMS_SIGNER_CERTIFICATE}"
  )"
  [ "${TRUSTED_CMS_SIGNER_SHA256}" = "${expected_signer_sha256}" ] \
    || die "${trusted_cms_label} signer certificate does not match the protected fingerprint"
}

verify_trusted_verification_receipt() (
  evidence_path="$1"
  signature_path="$2"
  expected_head="$3"
  archive_zip="$4"
  expected_app_fields="$5"
  signer_pin="${INFLOW_VERIFICATION_SIGNER_SHA256:-}"
  [ -n "${signer_pin}" ] \
    || die "INFLOW_VERIFICATION_SIGNER_SHA256 must be set by protected release configuration"
  require_system_trusted_detached_cms \
    "${evidence_path}" "${signature_path}" "${signer_pin}" \
    "repository verification"
  [ "$(plist_value "${TRUSTED_CMS_CONTENT}" verification_signer_sha256)" \
      = "${TRUSTED_CMS_SIGNER_SHA256}" ] \
    || die "verification receipt does not declare its actual pinned signer"
  verify_verification_contract \
    "${TRUSTED_CMS_CONTENT}" "${expected_head}" "${archive_zip}" \
    "${expected_app_fields}"
)

verify_trusted_release_manifest_identity_contract() (
  manifest_path="$1"
  signature_path="$2"
  expected_sequence="$3"
  expected_team_id="$4"
  expected_bundle_id="$5"
  expected_signer_sha256="$6"
  require_system_trusted_detached_cms \
    "${manifest_path}" "${signature_path}" "${expected_signer_sha256}" \
    "release manifest"
  verify_release_manifest_identity_with_signer \
    "${TRUSTED_CMS_CONTENT}" "${TRUSTED_CMS_SIGNER_CERTIFICATE}" \
    "${expected_sequence}" "${expected_team_id}" "${expected_bundle_id}" \
    "${expected_signer_sha256}"
)

verify_trusted_release_manifest() (
  manifest_path="$1"
  signature_path="$2"
  distribution_zip="$3"
  archive_zip="$4"
  minimum_release_sequence="$5"
  expected_team_id="$6"
  expected_bundle_id="$7"
  expected_signer_sha256="$8"
  require_system_trusted_detached_cms \
    "${manifest_path}" "${signature_path}" "${expected_signer_sha256}" \
    "release manifest"
  verify_release_manifest_contract \
    "${TRUSTED_CMS_CONTENT}" "${minimum_release_sequence}"
  trusted_release_sequence="$(
    plist_value "${TRUSTED_CMS_CONTENT}" release_sequence
  )"
  verify_release_manifest_identity_with_signer \
    "${TRUSTED_CMS_CONTENT}" "${TRUSTED_CMS_SIGNER_CERTIFICATE}" \
    "${trusted_release_sequence}" "${expected_team_id}" \
    "${expected_bundle_id}" "${expected_signer_sha256}"
  verify_bound_release_artifacts \
    "${TRUSTED_CMS_CONTENT}" "${distribution_zip}" "${archive_zip}"
  verify_safe_zip_payload "${distribution_zip}"
  verify_safe_zip_payload "${archive_zip}"
  echo "verified trust-root-pinned release sequence ${trusted_release_sequence}"
)

extract_zip_safely() {
  zip_path="$1"
  destination="$2"
  listing_path="$3"
  verify_zip "${zip_path}" >/dev/null
  /usr/bin/unzip -Z1 -- "${zip_path}" >"${listing_path}" \
    || die "could not enumerate ZIP entries"
  while IFS= read -r entry; do
    case "${entry}" in
      '' | /* | ../* | */../* | */.. | *'\'* )
        die "ZIP contains an unsafe entry path"
        ;;
    esac
  done <"${listing_path}"
  /bin/mkdir -p "${destination}"
  /usr/bin/ditto -x -k "${zip_path}" "${destination}" \
    || die "could not extract ZIP for identity verification"
  unexpected_entry="$({
    /usr/bin/find "${destination}" ! -type d ! -type f -print -quit
  } 2>/dev/null)"
  [ -z "${unexpected_entry}" ] \
    || die "ZIP payload contains a symlink or non-regular filesystem entry"
}

verify_safe_zip_payload() {
  safe_zip="$1"
  safe_root="$(/usr/bin/mktemp -d -t inflow-safe-zip-contract)"
  case "${safe_root}" in
    /private/tmp/* | /private/var/* | /tmp/* | /var/*) ;;
    *) die "refusing unexpected safe-ZIP verification path" ;;
  esac
  safe_listing="${safe_root}/entries.txt"
  safe_payload="${safe_root}/payload"
  extract_zip_safely "${safe_zip}" "${safe_payload}" "${safe_listing}"
  /bin/rm -rf -- "${safe_root}"
}

verify_distribution_zip_contains_app() {
  distribution_zip="$1"
  notarized_app="$2"
  extraction_root="$(/usr/bin/mktemp -d -t inflow-distribution-identity)"
  case "${extraction_root}" in
    /private/tmp/* | /private/var/* | /tmp/* | /var/*) ;;
    *) die "refusing unexpected distribution verification path" ;;
  esac
  listing_path="${extraction_root}/entries.txt"
  payload_root="${extraction_root}/payload"
  extract_zip_safely "${distribution_zip}" "${payload_root}" "${listing_path}"
  extracted_app="${payload_root}/Inflow.app"
  [ -d "${extracted_app}" ] \
    || { /bin/rm -rf -- "${extraction_root}"; die "distribution ZIP does not contain Inflow.app"; }
  unexpected_top="$({
    /usr/bin/find "${payload_root}" -mindepth 1 -maxdepth 1 \
      ! -name Inflow.app ! -name __MACOSX -print -quit
  } 2>/dev/null)"
  [ -z "${unexpected_top}" ] \
    || { /bin/rm -rf -- "${extraction_root}"; die "distribution ZIP contains an unexpected top-level item"; }
  verify_notarized_app "${extracted_app}" >/dev/null \
    || { /bin/rm -rf -- "${extraction_root}"; die "distribution ZIP App is not notarized"; }
  /usr/bin/diff -qr "${notarized_app}" "${extracted_app}" >/dev/null \
    || { /bin/rm -rf -- "${extraction_root}"; die "distribution ZIP does not contain the supplied notarized App bytes"; }
  /bin/rm -rf -- "${extraction_root}"
}

verify_archive_zip_matches_receipt() {
  archive_zip="$1"
  evidence_path="$2"
  extraction_root="$(/usr/bin/mktemp -d -t inflow-archive-identity)"
  case "${extraction_root}" in
    /private/tmp/* | /private/var/* | /tmp/* | /var/*) ;;
    *) die "refusing unexpected Archive verification path" ;;
  esac
  listing_path="${extraction_root}/entries.txt"
  payload_root="${extraction_root}/payload"
  extract_zip_safely "${archive_zip}" "${payload_root}" "${listing_path}"
  extracted_archive="${payload_root}/Inflow.xcarchive"
  [ -d "${extracted_archive}" ] \
    || { /bin/rm -rf -- "${extraction_root}"; die "Archive ZIP does not contain Inflow.xcarchive"; }
  unexpected_top="$({
    /usr/bin/find "${payload_root}" -mindepth 1 -maxdepth 1 \
      ! -name Inflow.xcarchive ! -name __MACOSX -print -quit
  } 2>/dev/null)"
  [ -z "${unexpected_top}" ] \
    || { /bin/rm -rf -- "${extraction_root}"; die "Archive ZIP contains an unexpected top-level item"; }
  "${VERIFY_ARCHIVE}" "${extracted_archive}" >/dev/null \
    || { /bin/rm -rf -- "${extraction_root}"; die "Archive ZIP no longer passes the signed Archive gate"; }
  expected_fields="${extraction_root}/archive-app-fields.json"
  write_expected_app_fields "$(archive_app_path "${extracted_archive}")" "${expected_fields}"
  verify_verification_app_fields "${evidence_path}" "${expected_fields}"
  /bin/rm -rf -- "${extraction_root}"
}

verify_product_baseline_contract() {
  evidence_path="$1"
  expected_head="$2"

  require_absolute_regular_file "${evidence_path}" "product baseline evidence"
  require_exact_flat_keys "${evidence_path}" "${PRODUCT_BASELINE_EVIDENCE_KEYS}"
  require_plist_type "${evidence_path}" schema_version integer
  for product_string_field in \
    status baseline_id source_head document_set_sha256 approver_id approved_at_utc
  do
    require_plist_type "${evidence_path}" "${product_string_field}" string
  done
  [ "$(plist_value "${evidence_path}" schema_version)" = "1" ] \
    || die "unsupported product baseline evidence schema"
  [ "$(plist_value "${evidence_path}" status)" = "approved" ] \
    || die "product baseline is not approved"
  [ "$(plist_value "${evidence_path}" source_head)" = "${expected_head}" ] \
    || die "product baseline evidence does not bind source HEAD ${expected_head}"
  PRODUCT_BASELINE_ID="$(
    require_nonempty_evidence_value "${evidence_path}" baseline_id
  )"
  PRODUCT_DOCUMENT_SET_SHA256="$(
    require_nonempty_evidence_value "${evidence_path}" document_set_sha256
  )"
  require_sha256_value "${PRODUCT_DOCUMENT_SET_SHA256}" "product document-set hash"
  PRODUCT_APPROVER_ID="$(
    require_nonempty_evidence_value "${evidence_path}" approver_id
  )"
  PRODUCT_APPROVED_AT="$(
    require_nonempty_evidence_value "${evidence_path}" approved_at_utc
  )"
  echo "${PRODUCT_APPROVED_AT}" \
    | /usr/bin/grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || die "product approval time must be a UTC RFC 3339 timestamp"
}

verify_performance_contract() {
  evidence_path="$1"
  expected_head="$2"
  performance_manifest="${3:-${CODE_ROOT}/quality/performance-manifest.json}"

  require_absolute_regular_file "${performance_manifest}" "performance manifest"
  require_absolute_regular_file "${evidence_path}" "performance evidence"
  require_exact_flat_keys "${evidence_path}" "${PERFORMANCE_EVIDENCE_KEYS}"
  for performance_integer_field in \
    schema_version physical_memory_bytes text_fixture_bytes text_fixture_lines \
    image_count image_total_bytes warmup_runs measured_runs post_restart_wait_seconds \
    cold_minimum_not_running_seconds warm_idle_seconds latency_sample_count \
    resource_sample_window_seconds continuous_input_duration_seconds \
    aggregate_rss_peak_bytes
  do
    require_plist_type "${evidence_path}" "${performance_integer_field}" integer
  done
  for performance_boolean_field in \
    dirty device_restarted other_foreground_apps_closed cold_inflow_exited \
    statistics_complete process_tree_complete authoritative_latency_samples_complete
  do
    performance_boolean_value="$(
      plist_value "${evidence_path}" "${performance_boolean_field}"
    )"
    case "${performance_boolean_value}" in
      true) require_plist_type "${evidence_path}" "${performance_boolean_field}" true ;;
      false) require_plist_type "${evidence_path}" "${performance_boolean_field}" false ;;
      *) die "invalid boolean performance field '${performance_boolean_field}'" ;;
    esac
  done
  for performance_number_field in \
    preview_update_p95_milliseconds view_switch_maximum_milliseconds \
    input_pause_p95_milliseconds input_pause_maximum_milliseconds \
    blank_window_median_milliseconds blank_window_maximum_milliseconds \
    warm_open_median_milliseconds warm_open_p95_milliseconds \
    cold_open_median_milliseconds cold_open_maximum_milliseconds \
    aggregate_cpu_window_percent
  do
    require_plist_number_type "${evidence_path}" "${performance_number_field}"
  done
  for performance_string_field in \
    status source_head manifest_sha256 model_identifier macos_version macos_build \
    architecture text_fixture_sha256 structure_fixture_sha256 image_corpus_sha256 \
    full_fixture_sha256 full_fixture_status cold_start_event warm_inflow_state \
    warm_start_event raw_samples_sha256 statistics_sha256 process_tree_sha256
  do
    require_plist_type "${evidence_path}" "${performance_string_field}" string
  done
  [ "$(plist_value "${performance_manifest}" fixture.full_fixture_status)" = "passed" ] \
    || die "repository performance manifest still marks the full fixture OPEN"
  [ "$(plist_value "${performance_manifest}" fixture.structure_distribution.status)" = "passed" ] \
    || die "repository performance manifest still marks the structure fixture OPEN"
  [ "$(plist_value "${performance_manifest}" fixture.local_images.status)" = "passed" ] \
    || die "repository performance manifest still marks the image fixture OPEN"
  [ "$(plist_value "${performance_manifest}" performance_budgets.status)" = "approved" ] \
    || die "performance budgets, including aggregate CPU/RSS, are not approved"
  expected_os_build="$(plist_value "${performance_manifest}" authoritative_target.operating_system_build)"
  [ -n "${expected_os_build}" ] && [ "${expected_os_build}" != "null" ] \
    || die "performance manifest does not freeze an exact macOS build"
  manifest_structure_hash="$(plist_value "${performance_manifest}" fixture.structure_distribution.sha256)"
  manifest_image_hash="$(plist_value "${performance_manifest}" fixture.local_images.corpus_sha256)"
  manifest_full_hash="$(plist_value "${performance_manifest}" fixture.full_fixture_sha256)"
  require_sha256_value "${manifest_structure_hash}" "manifest structure fixture hash"
  require_sha256_value "${manifest_image_hash}" "manifest image corpus hash"
  require_sha256_value "${manifest_full_hash}" "manifest full fixture hash"

  PERFORMANCE_MANIFEST_SHA256="$(sha256 "${performance_manifest}")"
  [ "$(plist_value "${evidence_path}" schema_version)" = "1" ] \
    || die "unsupported performance evidence schema"
  [ "$(plist_value "${evidence_path}" status)" = "passed" ] \
    || die "authoritative performance evidence status is not passed"
  [ "$(plist_value "${evidence_path}" source_head)" = "${expected_head}" ] \
    || die "performance evidence does not bind source HEAD ${expected_head}"
  [ "$(plist_value "${evidence_path}" dirty)" = "false" ] \
    || die "performance evidence was produced from a dirty worktree"
  [ "$(plist_value "${evidence_path}" manifest_sha256)" = "${PERFORMANCE_MANIFEST_SHA256}" ] \
    || die "performance evidence does not bind the current performance manifest"
  [ "$(plist_value "${evidence_path}" model_identifier)" = "$(plist_value "${performance_manifest}" authoritative_target.model_identifier)" ] \
    || die "performance evidence was not produced on the required model"
  [ "$(plist_value "${evidence_path}" physical_memory_bytes)" = "$(plist_value "${performance_manifest}" authoritative_target.physical_memory_bytes)" ] \
    || die "performance evidence has the wrong physical memory"
  [ "$(plist_value "${evidence_path}" macos_version)" = "$(plist_value "${performance_manifest}" authoritative_target.operating_system_version)" ] \
    || die "performance evidence has the wrong exact macOS version"
  [ "$(plist_value "${evidence_path}" architecture)" = "arm64" ] \
    || die "performance evidence has the wrong architecture"
  require_nonempty_evidence_value "${evidence_path}" macos_build >/dev/null
  [ "$(plist_value "${evidence_path}" macos_build)" = "${expected_os_build}" ] \
    || die "performance evidence has the wrong exact macOS build"
  [ "$(plist_value "${evidence_path}" text_fixture_sha256)" = "$(plist_value "${performance_manifest}" fixture.sha256)" ] \
    || die "performance evidence does not bind the exact text fixture"
  [ "$(plist_value "${evidence_path}" text_fixture_bytes)" = "1048576" ] \
    || die "performance evidence text fixture is not exactly 1 MiB"
  [ "$(plist_value "${evidence_path}" text_fixture_lines)" = "10000" ] \
    || die "performance evidence text fixture does not contain 10,000 lines"
  [ "$(plist_value "${evidence_path}" full_fixture_status)" = "passed" ] \
    || die "the structured image fixture is not complete"
  [ "$(plist_value "${evidence_path}" image_count)" = "20" ] \
    || die "performance evidence does not include exactly 20 images"
  [ "$(plist_value "${evidence_path}" image_total_bytes)" = "16777216" ] \
    || die "performance image corpus is not exactly 16 MiB"
  PERFORMANCE_IMAGE_CORPUS_SHA256="$(plist_value "${evidence_path}" image_corpus_sha256)"
  PERFORMANCE_STRUCTURE_FIXTURE_SHA256="$(plist_value "${evidence_path}" structure_fixture_sha256)"
  PERFORMANCE_FULL_FIXTURE_SHA256="$(plist_value "${evidence_path}" full_fixture_sha256)"
  require_sha256_value "${PERFORMANCE_IMAGE_CORPUS_SHA256}" "image corpus hash"
  require_sha256_value "${PERFORMANCE_STRUCTURE_FIXTURE_SHA256}" "structured fixture hash"
  require_sha256_value "${PERFORMANCE_FULL_FIXTURE_SHA256}" "full fixture hash"
  [ "${PERFORMANCE_STRUCTURE_FIXTURE_SHA256}" = "${manifest_structure_hash}" ] \
    || die "performance evidence does not bind the versioned structure fixture"
  [ "${PERFORMANCE_IMAGE_CORPUS_SHA256}" = "${manifest_image_hash}" ] \
    || die "performance evidence does not bind the versioned image corpus"
  [ "${PERFORMANCE_FULL_FIXTURE_SHA256}" = "${manifest_full_hash}" ] \
    || die "performance evidence does not bind the versioned full fixture"
  [ "$(plist_value "${evidence_path}" warmup_runs)" = "3" ] \
    || die "performance evidence does not contain 3 warmups"
  [ "$(plist_value "${evidence_path}" measured_runs)" = "30" ] \
    || die "performance evidence does not contain 30 measured runs"
  [ "$(plist_value "${evidence_path}" device_restarted)" = "true" ] \
    || die "performance measurement session did not start from a device restart"
  [ "$(plist_value "${evidence_path}" post_restart_wait_seconds)" = "$(plist_value "${performance_manifest}" measurement.measurement_session_preparation.post_restart_wait_seconds)" ] \
    || die "performance measurement session did not wait 5 minutes after restart"
  [ "$(plist_value "${evidence_path}" other_foreground_apps_closed)" = "true" ] \
    || die "performance measurement session left other foreground apps open"
  [ "$(plist_value "${evidence_path}" cold_inflow_exited)" = "true" ] \
    || die "cold-open evidence did not start with Inflow exited"
  [ "$(plist_value "${evidence_path}" cold_minimum_not_running_seconds)" = "$(plist_value "${performance_manifest}" measurement.cold_definition.minimum_not_running_seconds)" ] \
    || die "cold-open evidence does not include the required 30-second idle period"
  [ "$(plist_value "${evidence_path}" cold_start_event)" = "$(plist_value "${performance_manifest}" measurement.cold_definition.start_event)" ] \
    || die "cold-open evidence does not start from the Finder open request"
  [ "$(plist_value "${evidence_path}" warm_inflow_state)" = "$(plist_value "${performance_manifest}" measurement.warm_definition.inflow_state)" ] \
    || die "warm-open evidence did not start from one blank window"
  [ "$(plist_value "${evidence_path}" warm_idle_seconds)" = "$(plist_value "${performance_manifest}" measurement.warm_definition.idle_seconds)" ] \
    || die "warm-open evidence does not include the required 10-second idle period"
  [ "$(plist_value "${evidence_path}" warm_start_event)" = "$(plist_value "${performance_manifest}" measurement.warm_definition.start_event)" ] \
    || die "warm-open evidence does not start when the user confirms file open"
  [ "$(plist_value "${evidence_path}" latency_sample_count)" = "30" ] \
    || die "performance evidence latency sample count is incomplete"
  [ "$(plist_value "${evidence_path}" resource_sample_window_seconds)" = "30" ] \
    || die "performance evidence resource window is not 30 seconds"
  [ "$(plist_value "${evidence_path}" continuous_input_duration_seconds)" = "60" ] \
    || die "performance evidence continuous-input run is not 60 seconds"
  [ "$(plist_value "${evidence_path}" statistics_complete)" = "true" ] \
    || die "median/p95/maximum statistics are incomplete"
  [ "$(plist_value "${evidence_path}" process_tree_complete)" = "true" ] \
    || die "process-tree ownership evidence is incomplete"
  metric_contract='preview_update_p95_milliseconds:preview_update_p95_milliseconds,view_switch_maximum_milliseconds:view_switch_maximum_milliseconds,input_pause_p95_milliseconds:input_pause_p95_milliseconds,input_pause_maximum_milliseconds:input_pause_maximum_milliseconds,blank_window_median_milliseconds:blank_window_median_milliseconds,blank_window_maximum_milliseconds:blank_window_maximum_milliseconds,warm_open_median_milliseconds:warm_open_median_milliseconds,warm_open_p95_milliseconds:warm_open_p95_milliseconds,cold_open_median_milliseconds:cold_open_median_milliseconds,cold_open_maximum_milliseconds:cold_open_maximum_milliseconds,aggregate_rss_peak_bytes:aggregate_rss_peak_bytes,aggregate_cpu_window_percent:aggregate_cpu_window_percent'
  remaining_metrics="${metric_contract}"
  while [ -n "${remaining_metrics}" ]; do
    metric_pair="${remaining_metrics%%,*}"
    if [ "${remaining_metrics}" = "${metric_pair}" ]; then
      remaining_metrics=""
    else
      remaining_metrics="${remaining_metrics#*,}"
    fi
    evidence_metric="${metric_pair%%:*}"
    budget_metric="${metric_pair#*:}"
    actual_value="$(plist_value "${evidence_path}" "${evidence_metric}")"
    maximum_value="$(plist_value "${performance_manifest}" "performance_budgets.${budget_metric}")"
    echo "${actual_value}:${maximum_value}" \
      | /usr/bin/grep -Eq '^[0-9]+([.][0-9]+)?:[0-9]+([.][0-9]+)?$' \
      || die "performance metric '${evidence_metric}' or its budget is not numeric"
    /usr/bin/awk -v actual="${actual_value}" -v maximum="${maximum_value}" \
      'BEGIN { exit !(actual <= maximum) }' \
      || die "performance metric '${evidence_metric}' exceeds the approved budget"
  done
  PERFORMANCE_RAW_SAMPLES_SHA256="$(plist_value "${evidence_path}" raw_samples_sha256)"
  PERFORMANCE_STATISTICS_SHA256="$(plist_value "${evidence_path}" statistics_sha256)"
  PERFORMANCE_PROCESS_TREE_SHA256="$(plist_value "${evidence_path}" process_tree_sha256)"
  require_sha256_value "${PERFORMANCE_RAW_SAMPLES_SHA256}" "raw performance samples hash"
  require_sha256_value "${PERFORMANCE_STATISTICS_SHA256}" "performance statistics hash"
  require_sha256_value "${PERFORMANCE_PROCESS_TREE_SHA256}" "performance process-tree hash"
  [ "$(plist_value "${evidence_path}" authoritative_latency_samples_complete)" = "true" ] \
    || die "authoritative M1/8 GiB/macOS 14.0 latency, CPU, and RSS evidence is incomplete"
}

verify_evidence_receipts() {
  expected_head="$1"
  performance_evidence="$2"
  performance_signature="$3"
  product_baseline_evidence="$4"
  product_baseline_signature="$5"

  performance_signer_pin="${INFLOW_PERFORMANCE_SIGNER_SHA256:-}"
  product_signer_pin="${INFLOW_PRODUCT_APPROVAL_SIGNER_SHA256:-}"
  [ -n "${performance_signer_pin}" ] \
    || die "INFLOW_PERFORMANCE_SIGNER_SHA256 must be set by protected release configuration"
  [ -n "${product_signer_pin}" ] \
    || die "INFLOW_PRODUCT_APPROVAL_SIGNER_SHA256 must be set by protected release configuration"
  PERFORMANCE_SIGNER_SHA256="$(
    verify_pinned_evidence_signature \
      "${performance_evidence}" "${performance_signature}" \
      "${performance_signer_pin}" "performance"
  )"
  PRODUCT_SIGNER_SHA256="$(
    verify_pinned_evidence_signature \
      "${product_baseline_evidence}" "${product_baseline_signature}" \
      "${product_signer_pin}" "product baseline"
  )"
  verify_performance_contract "${performance_evidence}" "${expected_head}"
  verify_product_baseline_contract "${product_baseline_evidence}" "${expected_head}"
}

[ "$#" -ge 1 ] || {
  usage >&2
  exit 64
}

command_name="$1"
shift

case "${command_name}" in
  help | --help | -h)
    require_argument_count "$#" 0 0
    usage
    ;;

  check)
    require_argument_count "$#" 0 0
    exec "${VERIFY_LAUNCH}" --deferred-release-local
    ;;

  candidate)
    require_argument_count "$#" 0 1
    require_command xcodebuild
    require_clean_repository
    output_root="$(make_absolute_directory "${1:-${DEFAULT_OUTPUT_ROOT}}")"
    output_directory="$(fresh_output_directory "${output_root}" Inflow-local)"
    archive_path="${output_directory}/Inflow.xcarchive"
    evidence_path="${output_directory}/verification-evidence.json"
    INFLOW_REQUIRE_CLEAN_HEAD=1 \
      INFLOW_VERIFICATION_EVIDENCE_PATH="${evidence_path}" \
      INFLOW_LOCAL_ARCHIVE_PATH="${archive_path}" \
      "${VERIFY_LAUNCH}" --deferred-release-local
    write_zip_and_hash "${archive_path}" "${output_directory}/Inflow.xcarchive.zip"
    echo "archive: ${archive_path}"
    echo "verification evidence: ${evidence_path}"
    echo "local candidate passed every automated gate; it is not signed for distribution"
    ;;

  verify-local-archive)
    require_argument_count "$#" 1 1
    "${VERIFY_ARCHIVE}" --local "$1"
    ;;

  verify-zip)
    require_argument_count "$#" 1 1
    verify_zip "$1"
    ;;

  verify-safe-zip-payload)
    require_argument_count "$#" 1 1
    verify_safe_zip_payload "$1"
    echo "verified ZIP extraction contains only self-contained regular entries"
    ;;

  developer-id-archive)
    require_argument_count "$#" 1 2
    require_command xcodebuild
    require_clean_repository
    team_id="$1"
    manual_update_url="${INFLOW_MANUAL_UPDATE_URL:-}"
    verification_identity="${INFLOW_VERIFICATION_SIGNING_IDENTITY:-}"
    verification_signer_pin="${INFLOW_VERIFICATION_SIGNER_SHA256:-}"
    output_root="$(make_absolute_directory "${2:-${DEFAULT_OUTPUT_ROOT}}")"
    case "${team_id}" in
      *[!A-Za-z0-9]* | '') die "TEAM_ID must contain only letters and digits" ;;
    esac
    [ -n "${manual_update_url}" ] \
      || die "INFLOW_MANUAL_UPDATE_URL must be supplied by protected release configuration"
    require_valid_manual_update_url "${manual_update_url}"
    [ -n "${verification_identity}" ] \
      || die "INFLOW_VERIFICATION_SIGNING_IDENTITY must be supplied by protected release configuration"
    require_sha256_value "${verification_signer_pin}" \
      "INFLOW_VERIFICATION_SIGNER_SHA256"
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/grep -E "Developer ID Application: .+ \\(${team_id}\\)" >/dev/null \
      || die "no Developer ID Application certificate for team ${team_id} is installed"
    output_directory="$(fresh_output_directory "${output_root}" Inflow-developer-id)"
    archive_path="${output_directory}/Inflow.xcarchive"
    /usr/bin/xcodebuild \
      -project "${PROJECT_PATH}" \
      -scheme Inflow \
      -configuration Release \
      -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath "${output_directory}/DerivedData" \
      -archivePath "${archive_path}" \
      DEVELOPMENT_TEAM="${team_id}" \
      CODE_SIGN_STYLE=Manual \
      'CODE_SIGN_IDENTITY=Developer ID Application' \
      INFLOW_RELEASE_PROFILE=signed-preview \
      "INFLOW_SOURCE_HEAD=$(/usr/bin/git -C "${REPOSITORY_ROOT}" rev-parse HEAD)" \
      "INFLOW_MANUAL_UPDATE_URL=${manual_update_url}" \
      archive
    require_developer_id_signature "$(archive_app_path "${archive_path}")" "${team_id}"
    evidence_path="${output_directory}/verification-evidence.json"
    evidence_signature_path="${output_directory}/verification-evidence.json.cms"
    evidence_artifacts="${output_directory}/verification-artifacts"
    archive_zip="${output_directory}/Inflow.xcarchive.zip"
    write_zip_and_hash "${archive_path}" "${archive_zip}"
    INFLOW_REQUIRE_CLEAN_HEAD=1 \
      INFLOW_VERIFICATION_EVIDENCE_PATH="${evidence_path}" \
      INFLOW_VERIFICATION_EVIDENCE_SIGNATURE_PATH="${evidence_signature_path}" \
      INFLOW_VERIFICATION_ARTIFACT_DIRECTORY="${evidence_artifacts}" \
      INFLOW_VERIFICATION_ARCHIVE_ZIP_PATH="${archive_zip}" \
      INFLOW_VERIFICATION_SIGNING_IDENTITY="${verification_identity}" \
      INFLOW_VERIFICATION_SIGNER_SHA256="${verification_signer_pin}" \
      "${VERIFY_LAUNCH}" --deferred-signed-archive "${archive_path}"
    echo "Developer ID archive: ${archive_path}"
    echo "verification evidence: ${evidence_path}"
    echo "verification evidence signature: ${evidence_signature_path}"
    echo "next: $0 notarize '${archive_path}' KEYCHAIN_PROFILE"
    ;;

  notarize)
    require_argument_count "$#" 2 3
    archive_path="$1"
    keychain_profile="$2"
    [ -d "${archive_path}" ] || die "archive does not exist: ${archive_path}"
    output_root="$(make_absolute_directory "${3:-${DEFAULT_OUTPUT_ROOT}}")"
    archived_app="$(archive_app_path "${archive_path}")"
    require_developer_id_signature "${archived_app}"
    "${VERIFY_LAUNCH}" --deferred-signed-archive "${archive_path}"

    output_directory="$(fresh_output_directory "${output_root}" Inflow-notarized)"
    staged_app="${output_directory}/Inflow.app"
    submission_zip="${output_directory}/Inflow-notary-submission.zip"
    final_zip="${output_directory}/Inflow-notarized.zip"
    result_path="${output_directory}/notary-result.json"
    log_path="${output_directory}/notary-log.json"

    /usr/bin/ditto "${archived_app}" "${staged_app}"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
      "${staged_app}" "${submission_zip}"
    /usr/bin/xcrun notarytool submit "${submission_zip}" \
      --keychain-profile "${keychain_profile}" \
      --wait \
      --output-format json >"${result_path}"
    submission_status="$(/usr/bin/plutil -extract status raw "${result_path}")"
    submission_id="$(/usr/bin/plutil -extract id raw "${result_path}")"
    /usr/bin/xcrun notarytool log "${submission_id}" \
      --keychain-profile "${keychain_profile}" "${log_path}"
    [ "${submission_status}" = "Accepted" ] \
      || die "notarization was not accepted; inspect ${log_path}"

    /usr/bin/xcrun stapler staple "${staged_app}"
    verify_notarized_app "${staged_app}"
    write_zip_and_hash "${staged_app}" "${final_zip}"
    echo "notary result: ${result_path}"
    echo "notary log: ${log_path}"
    echo "notarized app: ${staged_app}"
    ;;

  verify-evidence-receipts)
    require_argument_count "$#" 5 5
    verify_evidence_receipts "$1" "$2" "$3" "$4" "$5"
    echo "verified pinned product-baseline and authoritative-performance receipts"
    ;;

  verify-performance-receipt)
    require_argument_count "$#" 4 4
    performance_signer_pin="${INFLOW_PERFORMANCE_SIGNER_SHA256:-}"
    [ -n "${performance_signer_pin}" ] \
      || die "INFLOW_PERFORMANCE_SIGNER_SHA256 must be set"
    verify_pinned_evidence_signature \
      "$1" "$2" "${performance_signer_pin}" "performance" >/dev/null
    verify_performance_contract "$1" "$3" "$4"
    echo "verified pinned performance receipt against complete manifest"
    ;;

  verify-product-baseline-receipt)
    require_argument_count "$#" 3 3
    product_signer_pin="${INFLOW_PRODUCT_APPROVAL_SIGNER_SHA256:-}"
    [ -n "${product_signer_pin}" ] \
      || die "INFLOW_PRODUCT_APPROVAL_SIGNER_SHA256 must be set"
    verify_pinned_evidence_signature \
      "$1" "$2" "${product_signer_pin}" "product baseline" >/dev/null
    verify_product_baseline_contract "$1" "$3"
    echo "verified pinned approved product baseline receipt"
    ;;

  verify-verification-receipt)
    require_argument_count "$#" 5 5
    verify_verification_receipt "$1" "$2" "$3" "$4" "$5"
    echo "verified pinned closed-world repository verification receipt"
    ;;

  verify-trusted-verification-receipt)
    require_argument_count "$#" 5 5
    verify_trusted_verification_receipt "$1" "$2" "$3" "$4" "$5"
    echo "verified trusted pinned repository verification receipt"
    ;;

  verify-predecessor-identity)
    require_argument_count "$#" 6 6
    verify_release_manifest_identity_contract "$1" "$2" "$3" "$4" "$5" "$6"
    echo "verified predecessor release identity and channel contract"
    ;;

  seal-release)
    require_argument_count "$#" 11 11
    require_clean_repository
    release_sequence="$1"
    notarized_app="$2"
    distribution_zip="$3"
    archive_zip="$4"
    verification_evidence="$5"
    verification_signature="$6"
    performance_evidence="$7"
    performance_signature="$8"
    product_baseline_evidence="$9"
    product_baseline_signature="${10}"
    output_directory="${11}"

    case "${notarized_app}" in
      /*) ;;
      *) die "APP must be an absolute path" ;;
    esac
    [ -d "${notarized_app}" ] && [ ! -L "${notarized_app}" ] \
      || die "APP must be a non-symlink application directory"

    case "${release_sequence}" in
      *[!0-9]* | '' | 0) die "SEQUENCE must be a positive integer" ;;
    esac
    case "${output_directory}" in
      /*) ;;
      *) die "OUTPUT_DIRECTORY must be absolute" ;;
    esac
    [ ! -e "${output_directory}" ] \
      || die "refusing to replace existing output: ${output_directory}"

    NOTARIZED_APP_SOURCE="${notarized_app}"
    DISTRIBUTION_ZIP_SOURCE="${distribution_zip}"
    ARCHIVE_ZIP_SOURCE="${archive_zip}"
    VERIFICATION_EVIDENCE_SOURCE="${verification_evidence}"
    VERIFICATION_SIGNATURE_SOURCE="${verification_signature}"
    PERFORMANCE_EVIDENCE_SOURCE="${performance_evidence}"
    PERFORMANCE_SIGNATURE_SOURCE="${performance_signature}"
    PRODUCT_EVIDENCE_SOURCE="${product_baseline_evidence}"
    PRODUCT_SIGNATURE_SOURCE="${product_baseline_signature}"

    require_absolute_regular_file "${DISTRIBUTION_ZIP_SOURCE}" "distribution ZIP"
    require_absolute_regular_file "${ARCHIVE_ZIP_SOURCE}" "Archive ZIP"
    require_absolute_regular_file "${VERIFICATION_EVIDENCE_SOURCE}" "verification evidence"
    require_absolute_regular_file "${VERIFICATION_SIGNATURE_SOURCE}" "verification evidence CMS"
    require_absolute_regular_file "${PERFORMANCE_EVIDENCE_SOURCE}" "performance evidence"
    require_absolute_regular_file "${PERFORMANCE_SIGNATURE_SOURCE}" "performance evidence CMS"
    require_absolute_regular_file "${PRODUCT_EVIDENCE_SOURCE}" "product baseline evidence"
    require_absolute_regular_file "${PRODUCT_SIGNATURE_SOURCE}" "product baseline evidence CMS"

    SEAL_STAGING_ROOT="$(/usr/bin/mktemp -d -t inflow-seal-snapshot)"
    case "${SEAL_STAGING_ROOT}" in
      /private/tmp/* | /private/var/* | /tmp/* | /var/*) ;;
      *) die "refusing unexpected release snapshot path" ;;
    esac
    /bin/chmod 700 "${SEAL_STAGING_ROOT}"
    trap '/bin/rm -rf -- "${SEAL_STAGING_ROOT}"' EXIT HUP INT TERM

    notarized_app="${SEAL_STAGING_ROOT}/Inflow.app"
    /usr/bin/ditto "${NOTARIZED_APP_SOURCE}" "${notarized_app}" \
      || die "could not snapshot notarized App"
    [ -d "${notarized_app}" ] && [ ! -L "${notarized_app}" ] \
      || die "staged App is not a self-contained application directory"
    unexpected_app_symlink="$({
      /usr/bin/find "${notarized_app}" -type l -print -quit
    } 2>/dev/null)"
    [ -z "${unexpected_app_symlink}" ] \
      || die "notarized App snapshot contains a symlink"

    distribution_zip="${SEAL_STAGING_ROOT}/distribution.zip"
    archive_zip="${SEAL_STAGING_ROOT}/archive.zip"
    verification_evidence="${SEAL_STAGING_ROOT}/verification-evidence.json"
    verification_signature="${SEAL_STAGING_ROOT}/verification-evidence.json.cms"
    performance_evidence="${SEAL_STAGING_ROOT}/performance-evidence.json"
    performance_signature="${SEAL_STAGING_ROOT}/performance-evidence.json.cms"
    product_baseline_evidence="${SEAL_STAGING_ROOT}/product-baseline-evidence.json"
    product_baseline_signature="${SEAL_STAGING_ROOT}/product-baseline-evidence.json.cms"
    snapshot_regular_file "${DISTRIBUTION_ZIP_SOURCE}" "${distribution_zip}" "distribution ZIP"
    snapshot_regular_file "${ARCHIVE_ZIP_SOURCE}" "${archive_zip}" "Archive ZIP"
    snapshot_regular_file "${VERIFICATION_EVIDENCE_SOURCE}" "${verification_evidence}" "verification evidence"
    snapshot_regular_file "${VERIFICATION_SIGNATURE_SOURCE}" "${verification_signature}" "verification evidence CMS"
    snapshot_regular_file "${PERFORMANCE_EVIDENCE_SOURCE}" "${performance_evidence}" "performance evidence"
    snapshot_regular_file "${PERFORMANCE_SIGNATURE_SOURCE}" "${performance_signature}" "performance evidence CMS"
    snapshot_regular_file "${PRODUCT_EVIDENCE_SOURCE}" "${product_baseline_evidence}" "product baseline evidence"
    snapshot_regular_file "${PRODUCT_SIGNATURE_SOURCE}" "${product_baseline_signature}" "product baseline evidence CMS"

    SEALED_DISTRIBUTION_ZIP_SHA256="$(sha256 "${distribution_zip}")"
    SEALED_ARCHIVE_ZIP_SHA256="$(sha256 "${archive_zip}")"
    SEALED_VERIFICATION_EVIDENCE_SHA256="$(sha256 "${verification_evidence}")"
    SEALED_VERIFICATION_SIGNATURE_SHA256="$(sha256 "${verification_signature}")"
    SEALED_PERFORMANCE_EVIDENCE_SHA256="$(sha256 "${performance_evidence}")"
    SEALED_PERFORMANCE_SIGNATURE_SHA256="$(sha256 "${performance_signature}")"
    SEALED_PRODUCT_EVIDENCE_SHA256="$(sha256 "${product_baseline_evidence}")"
    SEALED_PRODUCT_SIGNATURE_SHA256="$(sha256 "${product_baseline_signature}")"
    SEALED_EVIDENCE_SCHEMA_SHA256="$(sha256 "${RELEASE_EVIDENCE_SCHEMA}")"

    verify_notarized_app "${notarized_app}"
    verify_zip "${distribution_zip}"
    verify_zip "${archive_zip}"

    current_head="$(/usr/bin/git -C "${REPOSITORY_ROOT}" rev-parse HEAD)"
    verify_evidence_receipts \
      "${current_head}" \
      "${performance_evidence}" "${performance_signature}" \
      "${product_baseline_evidence}" "${product_baseline_signature}"

    app_info="${notarized_app}/Contents/Info.plist"
    app_binary="${notarized_app}/Contents/MacOS/Inflow"
    [ -f "${app_info}" ] && [ -f "${app_binary}" ] \
      || die "notarized app is incomplete"
    [ "$(plist_value "${app_info}" InflowReleaseProfile)" = "signed-preview" ] \
      || die "release app does not carry the signed-preview release profile"
    manual_update_url="$(plist_value "${app_info}" InflowManualUpdateURL)"
    require_valid_manual_update_url "${manual_update_url}"
    update_authority="${manual_update_url#https://}"
    update_authority="${update_authority%%/*}"
    manual_update_origin="https://${update_authority}"
    bundle_id="$(plist_value "${app_info}" CFBundleIdentifier)"
    [ -n "${bundle_id}" ] || die "release app bundle ID is missing"
    marketing_version="$(plist_value "${app_info}" CFBundleShortVersionString)"
    build_version="$(plist_value "${app_info}" CFBundleVersion)"
    SEALED_APP_INFO_SHA256="$(sha256 "${app_info}")"
    SEALED_APP_BINARY_SHA256="$(sha256 "${app_binary}")"
    signature="$(signature_details "${notarized_app}")"
    authority="$(echo "${signature}" | /usr/bin/awk -F= '$1 == "Authority" { print $2; exit }')"
    team_id="$(echo "${signature}" | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
    app_cdhash="$(echo "${signature}" | /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }')"
    [ -n "${app_cdhash}" ] || die "release App CodeDirectory hash is missing"
    case "${authority}" in
      "Developer ID Application:"*) ;;
      *) die "release app is not Developer ID signed" ;;
    esac
    extract_app_signer_identity "${notarized_app}"
    [ "${APP_SIGNER_TEAM_ID}" = "${team_id}" ] \
      || die "notarized app certificate Team ID does not match its code-signing metadata"

    verification_contract_root="$(/usr/bin/mktemp -d -t inflow-verification-contract)"
    case "${verification_contract_root}" in
      /private/tmp/* | /private/var/* | /tmp/* | /var/*) ;;
      *) die "refusing unexpected verification-contract path" ;;
    esac
    expected_app_fields="${verification_contract_root}/notarized-app-fields.json"
    write_expected_app_fields "${notarized_app}" "${expected_app_fields}"
    verify_trusted_verification_receipt \
      "${verification_evidence}" "${verification_signature}" "${current_head}" \
      "${archive_zip}" "${expected_app_fields}"
    verify_archive_zip_matches_receipt "${archive_zip}" "${verification_evidence}"
    verify_distribution_zip_contains_app "${distribution_zip}" "${notarized_app}"
    VERIFICATION_SIGNER_SHA256="$(
      plist_value "${verification_evidence}" verification_signer_sha256
    )"
    [ "$(sha256 "${distribution_zip}")" = "${SEALED_DISTRIBUTION_ZIP_SHA256}" ] \
      && [ "$(sha256 "${archive_zip}")" = "${SEALED_ARCHIVE_ZIP_SHA256}" ] \
      && [ "$(sha256 "${verification_evidence}")" = "${SEALED_VERIFICATION_EVIDENCE_SHA256}" ] \
      && [ "$(sha256 "${verification_signature}")" = "${SEALED_VERIFICATION_SIGNATURE_SHA256}" ] \
      && [ "$(sha256 "${performance_evidence}")" = "${SEALED_PERFORMANCE_EVIDENCE_SHA256}" ] \
      && [ "$(sha256 "${performance_signature}")" = "${SEALED_PERFORMANCE_SIGNATURE_SHA256}" ] \
      && [ "$(sha256 "${product_baseline_evidence}")" = "${SEALED_PRODUCT_EVIDENCE_SHA256}" ] \
      && [ "$(sha256 "${product_baseline_signature}")" = "${SEALED_PRODUCT_SIGNATURE_SHA256}" ] \
      && [ "$(sha256 "${app_info}")" = "${SEALED_APP_INFO_SHA256}" ] \
      && [ "$(sha256 "${app_binary}")" = "${SEALED_APP_BINARY_SHA256}" ] \
      || die "a staged release input changed while it was being verified"
    [ "$(signature_details "${notarized_app}" \
          | /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }')" = "${app_cdhash}" ] \
      || die "staged App identity changed while it was being verified"
    /bin/rm -rf -- "${verification_contract_root}"

    previous_sequence=0
    previous_manifest_hash="none"
    previous_manifest_signature_hash="none"
    previous_manifest_source="${INFLOW_PREVIOUS_RELEASE_MANIFEST:-}"
    previous_signature_source="${INFLOW_PREVIOUS_RELEASE_SIGNATURE:-}"
    previous_manifest=""
    previous_signature=""
    if [ "${release_sequence}" -eq 1 ]; then
      [ -z "${previous_manifest_source}" ] && [ -z "${previous_signature_source}" ] \
        || die "release sequence 1 must not specify a predecessor"
    else
      [ -n "${previous_manifest_source}" ] && [ -n "${previous_signature_source}" ] \
        || die "later releases require the previous manifest and CMS signature"
      previous_manifest="${SEAL_STAGING_ROOT}/previous-release-manifest.json"
      previous_signature="${SEAL_STAGING_ROOT}/previous-release-manifest.json.cms"
      snapshot_regular_file \
        "${previous_manifest_source}" "${previous_manifest}" "previous release manifest"
      snapshot_regular_file \
        "${previous_signature_source}" "${previous_signature}" "previous release CMS"
      SEALED_PREVIOUS_MANIFEST_SHA256="$(sha256 "${previous_manifest}")"
      SEALED_PREVIOUS_SIGNATURE_SHA256="$(sha256 "${previous_signature}")"
      previous_sequence=$((release_sequence - 1))
      verify_trusted_release_manifest_identity_contract \
        "${previous_manifest}" "${previous_signature}" \
        "${previous_sequence}" "${team_id}" "${bundle_id}" \
        "${APP_SIGNER_SHA256}"
      [ "$(sha256 "${previous_manifest}")" = "${SEALED_PREVIOUS_MANIFEST_SHA256}" ] \
        && [ "$(sha256 "${previous_signature}")" = "${SEALED_PREVIOUS_SIGNATURE_SHA256}" ] \
        || die "staged predecessor changed while it was being verified"
      previous_manifest_hash="${SEALED_PREVIOUS_MANIFEST_SHA256}"
      previous_manifest_signature_hash="${SEALED_PREVIOUS_SIGNATURE_SHA256}"
    fi

    /bin/mkdir -p "${output_directory}"
    manifest_path="${output_directory}/release-manifest.json"
    signature_path="${output_directory}/release-manifest.json.cms"

    /usr/bin/plutil -create xml1 "${manifest_path}"
    /usr/bin/plutil -insert schema_version -integer 2 "${manifest_path}"
    /usr/bin/plutil -insert release_sequence -integer "${release_sequence}" "${manifest_path}"
    /usr/bin/plutil -insert previous_release_sequence -integer "${previous_sequence}" "${manifest_path}"
    /usr/bin/plutil -insert previous_manifest_sha256 -string "${previous_manifest_hash}" "${manifest_path}"
    /usr/bin/plutil -insert previous_manifest_signature_sha256 -string "${previous_manifest_signature_hash}" "${manifest_path}"
    /usr/bin/plutil -insert product_baseline_id -string "${PRODUCT_BASELINE_ID}" "${manifest_path}"
    /usr/bin/plutil -insert product_baseline_evidence_sha256 -string "${SEALED_PRODUCT_EVIDENCE_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert product_baseline_signature_sha256 -string "${SEALED_PRODUCT_SIGNATURE_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert product_baseline_signer_sha256 -string "${PRODUCT_SIGNER_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert product_document_set_sha256 -string "${PRODUCT_DOCUMENT_SET_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert product_approver_id -string "${PRODUCT_APPROVER_ID}" "${manifest_path}"
    /usr/bin/plutil -insert product_approved_at_utc -string "${PRODUCT_APPROVED_AT}" "${manifest_path}"
    /usr/bin/plutil -insert source_head -string "${current_head}" "${manifest_path}"
    /usr/bin/plutil -insert dirty -bool false "${manifest_path}"
    /usr/bin/plutil -insert marketing_version -string "${marketing_version}" "${manifest_path}"
    /usr/bin/plutil -insert build_version -string "${build_version}" "${manifest_path}"
    /usr/bin/plutil -insert channel -string stable-direct "${manifest_path}"
    /usr/bin/plutil -insert distribution_profile -string developer-id-notarized-zip "${manifest_path}"
    /usr/bin/plutil -insert bundle_id -string "${bundle_id}" "${manifest_path}"
    /usr/bin/plutil -insert update_mode -string manual-check "${manifest_path}"
    /usr/bin/plutil -insert manual_update_origin -string "${manual_update_origin}" "${manifest_path}"
    /usr/bin/plutil -insert app_info_plist_sha256 -string "${SEALED_APP_INFO_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert archive_zip_sha256 -string "${SEALED_ARCHIVE_ZIP_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert distribution_zip_sha256 -string "${SEALED_DISTRIBUTION_ZIP_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert app_binary_sha256 -string "${SEALED_APP_BINARY_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert app_cdhash -string "${app_cdhash}" "${manifest_path}"
    /usr/bin/plutil -insert verification_evidence_sha256 -string "${SEALED_VERIFICATION_EVIDENCE_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert verification_evidence_signature_sha256 -string "${SEALED_VERIFICATION_SIGNATURE_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert verification_evidence_signer_sha256 -string "${VERIFICATION_SIGNER_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert performance_evidence_sha256 -string "${SEALED_PERFORMANCE_EVIDENCE_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert performance_evidence_signature_sha256 -string "${SEALED_PERFORMANCE_SIGNATURE_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert performance_evidence_signer_sha256 -string "${PERFORMANCE_SIGNER_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert performance_manifest_sha256 -string "${PERFORMANCE_MANIFEST_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert release_evidence_schema_sha256 -string "${SEALED_EVIDENCE_SCHEMA_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert performance_full_fixture_sha256 -string "${PERFORMANCE_FULL_FIXTURE_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert performance_raw_samples_sha256 -string "${PERFORMANCE_RAW_SAMPLES_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert performance_statistics_sha256 -string "${PERFORMANCE_STATISTICS_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert performance_process_tree_sha256 -string "${PERFORMANCE_PROCESS_TREE_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert signing_authority -string "${authority}" "${manifest_path}"
    /usr/bin/plutil -insert team_id -string "${team_id}" "${manifest_path}"
    /usr/bin/plutil -insert signing_certificate_sha256 -string "${APP_SIGNER_SHA256}" "${manifest_path}"
    /usr/bin/plutil -insert signing_certificate_subject_rfc2253 -string "${APP_SIGNER_SUBJECT_RFC2253}" "${manifest_path}"
    /usr/bin/plutil -insert notarization_ticket_stapled -bool true "${manifest_path}"
    /usr/bin/plutil -insert created_at_utc -string "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "${manifest_path}"
    /usr/bin/plutil -convert json "${manifest_path}"

    [ -z "$(/usr/bin/git -C "${REPOSITORY_ROOT}" status --porcelain)" ] \
      && [ "$(/usr/bin/git -C "${REPOSITORY_ROOT}" rev-parse HEAD)" = "${current_head}" ] \
      || die "source state changed before release manifest signing"

    /usr/bin/security cms -S -T -G -H SHA256 -u 6 -N "${authority}" \
      -i "${manifest_path}" -o "${signature_path}" \
      || die "failed to sign the release manifest"
    verify_trusted_release_manifest_identity_contract \
      "${manifest_path}" "${signature_path}" "${release_sequence}" \
      "${team_id}" "${bundle_id}" "${APP_SIGNER_SHA256}"
    verify_bound_release_artifacts "${manifest_path}" "${distribution_zip}" "${archive_zip}"
    echo "signed monotonic release manifest: ${manifest_path}"
    echo "detached CMS signature: ${signature_path}"
    ;;

  verify-release-manifest)
    require_argument_count "$#" 4 4
    [ -z "${INFLOW_RELEASE_SIGNER_SHA256:-}" ] \
      && [ -z "${INFLOW_RELEASE_TEAM_ID:-}" ] \
      && [ -z "${INFLOW_RELEASE_BUNDLE_ID:-}" ] \
      || die "public verification does not accept caller-selected release identity"
    load_approved_release_trust_root
    PUBLIC_VERIFY_ROOT="$(/usr/bin/mktemp -d -t inflow-public-release)"
    case "${PUBLIC_VERIFY_ROOT}" in
      /private/tmp/* | /private/var/* | /tmp/* | /var/*) ;;
      *) die "refusing unexpected public verification path" ;;
    esac
    /bin/chmod 700 "${PUBLIC_VERIFY_ROOT}"
    public_manifest="${PUBLIC_VERIFY_ROOT}/release-manifest.json"
    public_signature="${PUBLIC_VERIFY_ROOT}/release-manifest.json.cms"
    public_distribution="${PUBLIC_VERIFY_ROOT}/distribution.zip"
    public_archive="${PUBLIC_VERIFY_ROOT}/archive.zip"
    snapshot_regular_file "$1" "${public_manifest}" "release manifest"
    snapshot_regular_file "$2" "${public_signature}" "release manifest CMS"
    snapshot_regular_file "$3" "${public_distribution}" "distribution ZIP"
    snapshot_regular_file "$4" "${public_archive}" "Archive ZIP"
    verify_trusted_release_manifest \
      "${public_manifest}" "${public_signature}" \
      "${public_distribution}" "${public_archive}" \
      "${RELEASE_TRUST_MINIMUM_SEQUENCE}" "${RELEASE_TRUST_TEAM_ID}" \
      "${RELEASE_TRUST_BUNDLE_ID}" "${RELEASE_TRUST_SIGNER_SHA256}"
    /bin/rm -rf -- "${PUBLIC_VERIFY_ROOT}"
    ;;

  verify-notarized-app)
    require_argument_count "$#" 1 1
    verify_notarized_app "$1"
    echo "verified notarized Developer ID app: $1"
    ;;

  open-archive)
    require_argument_count "$#" 1 1
    app_path="$(archive_app_path "$1")"
    [ -d "${app_path}" ] || die "Inflow app does not exist: ${app_path}"
    /usr/bin/open "${app_path}"
    ;;

  *)
    usage >&2
    exit 64
    ;;
esac
