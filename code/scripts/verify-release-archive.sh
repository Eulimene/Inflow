#!/bin/sh

set -eu

SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

contract_error() {
  echo "error: $*" >&2
  return 1
}

valid_manual_update_url() {
  candidate="$1"
  case "${candidate}" in
    '' | *[[:space:]]* | *..* | *'@'* | *'?'* | *'#'*) return 1 ;;
  esac
  printf '%s\n' "${candidate}" \
    | LC_ALL=C /usr/bin/grep -Eq '^https://[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9](/[A-Za-z0-9._~!$&()*+,;=%/-]*)?$'
}

valid_git_object_id() {
  printf '%s\n' "$1" \
    | LC_ALL=C /usr/bin/grep -Eq '^[0-9a-f]{40}([0-9a-f]{24})?$'
}

plist_raw_value() {
  plist_path="$1"
  key_path="$2"
  expected_type="$3"
  /usr/bin/plutil -extract "${key_path}" raw -expect "${expected_type}" \
    "${plist_path}" 2>/dev/null
}

plist_has_key() {
  plist_path="$1"
  key_path="$2"
  /usr/bin/plutil -type "${key_path}" "${plist_path}" >/dev/null 2>&1
}

require_exact_top_level_keys() {
  plist_path="$1"
  scratch_name="$2"
  shift 2
  remainder_path="${TEMPORARY_ROOT}/${scratch_name}-remainder.plist"
  if ! /bin/cp -f "${plist_path}" "${remainder_path}"; then
    contract_error "could not copy plist for closed-world validation: ${plist_path}"
    return 1
  fi
  for allowed_key_path in "$@"; do
    if ! /usr/bin/plutil -remove "${allowed_key_path}" "${remainder_path}" \
        >/dev/null 2>&1
    then
      contract_error "required plist key is missing: ${allowed_key_path}"
      return 1
    fi
  done
  if ! remaining_json="$(
    /usr/bin/plutil -convert json -o - "${remainder_path}" 2>/dev/null
  )"; then
    contract_error "could not inspect remaining plist keys: ${plist_path}"
    return 1
  fi
  if [ "${remaining_json}" != "{}" ]; then
    contract_error "plist contains a key outside the closed-world allowlist: ${plist_path}"
    return 1
  fi
}

verify_zero_collection_privacy_manifest() {
  privacy_path="$1"
  if ! /usr/bin/plutil -lint "${privacy_path}" >/dev/null; then
    contract_error "archived privacy manifest is invalid"
    return 1
  fi
  if [ "$(plist_raw_value "${privacy_path}" NSPrivacyTracking bool || true)" != "false" ]; then
    contract_error "privacy manifest must disable tracking"
    return 1
  fi
  for privacy_array_key in \
    NSPrivacyTrackingDomains \
    NSPrivacyCollectedDataTypes \
    NSPrivacyAccessedAPITypes
  do
    if [ "$(
      plist_raw_value "${privacy_path}" "${privacy_array_key}" array || true
    )" != "0" ]; then
      contract_error "privacy manifest array must exist and be empty: ${privacy_array_key}"
      return 1
    fi
  done
  require_exact_top_level_keys \
    "${privacy_path}" privacy \
    NSPrivacyTracking \
    NSPrivacyTrackingDomains \
    NSPrivacyCollectedDataTypes \
    NSPrivacyAccessedAPITypes
}

verify_entitlement_contract() {
  entitlement_path="$1"
  validation_mode="$2"
  expected_team_id="$3"
  expected_bundle_id="$4"

  sandbox_key='com\.apple\.security\.app-sandbox'
  user_files_key='com\.apple\.security\.files\.user-selected\.read-write'
  bookmarks_key='com\.apple\.security\.files\.bookmarks\.app-scope'
  network_client_key='com\.apple\.security\.network\.client'
  team_key='com\.apple\.developer\.team-identifier'
  application_identifier_key='com\.apple\.application-identifier'

  if ! /usr/bin/plutil -lint "${entitlement_path}" >/dev/null; then
    contract_error "signed entitlement plist is invalid"
    return 1
  fi
  for required_entitlement_key in \
    "${sandbox_key}" \
    "${user_files_key}" \
    "${bookmarks_key}" \
    "${network_client_key}"
  do
    if [ "$(
      plist_raw_value "${entitlement_path}" "${required_entitlement_key}" bool || true
    )" != "true" ]; then
      contract_error "required entitlement is missing or is not true: ${required_entitlement_key}"
      return 1
    fi
  done

  has_team_identifier=0
  has_application_identifier=0
  if plist_has_key "${entitlement_path}" "${team_key}"; then
    has_team_identifier=1
  fi
  if plist_has_key "${entitlement_path}" "${application_identifier_key}"; then
    has_application_identifier=1
  fi
  if [ "${has_team_identifier}" -ne "${has_application_identifier}" ]; then
    contract_error "signed identity entitlements must be absent together or present together"
    return 1
  fi

  if [ "${has_team_identifier}" -eq 1 ]; then
    if [ "${validation_mode}" != "signed" ]; then
      contract_error "local entitlement source must not declare distribution identity keys"
      return 1
    fi
    if [ -z "${expected_team_id}" ] || [ -z "${expected_bundle_id}" ]; then
      contract_error "signed identity entitlement validation requires Team ID and bundle ID"
      return 1
    fi
    declared_team_id="$(
      plist_raw_value "${entitlement_path}" "${team_key}" string || true
    )"
    declared_application_identifier="$(
      plist_raw_value "${entitlement_path}" "${application_identifier_key}" string || true
    )"
    if [ "${declared_team_id}" != "${expected_team_id}" ]; then
      contract_error "signed entitlement Team ID does not match the code signature"
      return 1
    fi
    if [ "${declared_application_identifier}" \
        != "${expected_team_id}.${expected_bundle_id}" ]; then
      contract_error "signed application identifier does not match Team ID and bundle ID"
      return 1
    fi
    require_exact_top_level_keys \
      "${entitlement_path}" entitlements \
      "${sandbox_key}" \
      "${user_files_key}" \
      "${bookmarks_key}" \
      "${network_client_key}" \
      "${team_key}" \
      "${application_identifier_key}"
    return
  fi

  require_exact_top_level_keys \
    "${entitlement_path}" entitlements \
    "${sandbox_key}" \
    "${user_files_key}" \
    "${bookmarks_key}" \
    "${network_client_key}"
}

assert_contract_rejects() {
  failure_label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    contract_error "self-test expected rejection: ${failure_label}"
    return 1
  fi
}

run_contract_self_test() {
  privacy_source="${SCRIPT_DIRECTORY}/../macos/Inflow/Resources/PrivacyInfo.xcprivacy"
  entitlement_source="${SCRIPT_DIRECTORY}/../macos/Inflow/Resources/Inflow.entitlements"

  valid_manual_update_url 'https://updates.example.test/inflow' \
    || contract_error "self-test rejected the valid manual-update URL"
  for rejected_url in \
    'https://updates.example.test/in flow' \
    "$(printf 'https://updates.example.test/inflow\tbad')" \
    "$(printf 'https://updates.example.test/inflow\nbad')" \
    "$(printf 'https://updates.example.test/inflow\rbad')"
  do
    if valid_manual_update_url "${rejected_url}"; then
      contract_error "self-test accepted whitespace in the manual-update URL"
      return 1
    fi
  done

  valid_git_object_id 0123456789abcdef0123456789abcdef01234567 \
    || contract_error "self-test rejected a valid source object ID"
  for rejected_source_head in \
    development-unbound \
    0123456789ABCDEF0123456789ABCDEF01234567 \
    0123456789abcdef0123456789abcdef0123456 \
    0123456789abcdef0123456789abcdef012345678
  do
    if valid_git_object_id "${rejected_source_head}"; then
      contract_error "self-test accepted an invalid source object ID"
      return 1
    fi
  done

  verify_zero_collection_privacy_manifest "${privacy_source}"
  privacy_tracking_tail="${TEMPORARY_ROOT}/privacy-tracking-tail.plist"
  /bin/cp -f "${privacy_source}" "${privacy_tracking_tail}"
  /usr/bin/plutil -insert NSPrivacyTrackingDomains.0 -string '' \
    "${privacy_tracking_tail}"
  /usr/bin/plutil -insert NSPrivacyTrackingDomains.1 -string tracker.example \
    "${privacy_tracking_tail}"
  assert_contract_rejects \
    'tracking domain hidden after an empty first item' \
    verify_zero_collection_privacy_manifest "${privacy_tracking_tail}"

  privacy_collected_tail="${TEMPORARY_ROOT}/privacy-collected-tail.plist"
  /bin/cp -f "${privacy_source}" "${privacy_collected_tail}"
  /usr/bin/plutil -insert NSPrivacyCollectedDataTypes.0 -dictionary \
    "${privacy_collected_tail}"
  /usr/bin/plutil -insert NSPrivacyCollectedDataTypes.1 -dictionary \
    "${privacy_collected_tail}"
  /usr/bin/plutil -insert \
    NSPrivacyCollectedDataTypes.1.NSPrivacyCollectedDataType \
    -string NSPrivacyCollectedDataTypeProductInteraction \
    "${privacy_collected_tail}"
  assert_contract_rejects \
    'collected data hidden after an empty first item' \
    verify_zero_collection_privacy_manifest "${privacy_collected_tail}"

  privacy_accessed_tail="${TEMPORARY_ROOT}/privacy-accessed-tail.plist"
  /bin/cp -f "${privacy_source}" "${privacy_accessed_tail}"
  /usr/bin/plutil -insert NSPrivacyAccessedAPITypes.0 -dictionary \
    "${privacy_accessed_tail}"
  /usr/bin/plutil -insert NSPrivacyAccessedAPITypes.1 -dictionary \
    "${privacy_accessed_tail}"
  /usr/bin/plutil -insert \
    NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPIType \
    -string NSPrivacyAccessedAPICategoryFileTimestamp \
    "${privacy_accessed_tail}"
  assert_contract_rejects \
    'accessed API hidden after an empty first item' \
    verify_zero_collection_privacy_manifest "${privacy_accessed_tail}"

  privacy_extra="${TEMPORARY_ROOT}/privacy-extra.plist"
  /bin/cp -f "${privacy_source}" "${privacy_extra}"
  /usr/bin/plutil -insert UnexpectedPrivacyKey -string hidden "${privacy_extra}"
  assert_contract_rejects \
    'privacy key outside the allowlist' \
    verify_zero_collection_privacy_manifest "${privacy_extra}"

  verify_entitlement_contract "${entitlement_source}" local '' com.inflow.desktop
  entitlement_missing_webkit_client="${TEMPORARY_ROOT}/entitlement-missing-webkit-client.plist"
  /bin/cp -f "${entitlement_source}" "${entitlement_missing_webkit_client}"
  /usr/bin/plutil -remove 'com\.apple\.security\.network\.client' \
    "${entitlement_missing_webkit_client}"
  assert_contract_rejects \
    'missing WebKit client entitlement' \
    verify_entitlement_contract \
      "${entitlement_missing_webkit_client}" local '' com.inflow.desktop
  for extra_entitlement in \
    'com\.apple\.security\.network\.server' \
    'com\.apple\.security\.application-groups' \
    'com\.apple\.security\.temporary-exception\.mach-lookup\.global-name'
  do
    entitlement_extra="${TEMPORARY_ROOT}/entitlement-extra.plist"
    /bin/cp -f "${entitlement_source}" "${entitlement_extra}"
    /usr/bin/plutil -insert "${extra_entitlement}" -bool true "${entitlement_extra}"
    assert_contract_rejects \
      "extra entitlement ${extra_entitlement}" \
      verify_entitlement_contract \
        "${entitlement_extra}" local '' com.inflow.desktop
  done

  signed_entitlements="${TEMPORARY_ROOT}/signed-identity.plist"
  /bin/cp -f "${entitlement_source}" "${signed_entitlements}"
  /usr/bin/plutil -insert 'com\.apple\.developer\.team-identifier' \
    -string TESTTEAM1 "${signed_entitlements}"
  /usr/bin/plutil -insert 'com\.apple\.application-identifier' \
    -string TESTTEAM1.com.inflow.desktop "${signed_entitlements}"
  verify_entitlement_contract \
    "${signed_entitlements}" signed TESTTEAM1 com.inflow.desktop
  assert_contract_rejects \
    'identity entitlement for another Team ID' \
    verify_entitlement_contract \
      "${signed_entitlements}" signed OTHERTEAM9 com.inflow.desktop

  incomplete_identity="${TEMPORARY_ROOT}/incomplete-identity.plist"
  /bin/cp -f "${signed_entitlements}" "${incomplete_identity}"
  /usr/bin/plutil -remove 'com\.apple\.application-identifier' \
    "${incomplete_identity}"
  assert_contract_rejects \
    'only one signed identity entitlement' \
    verify_entitlement_contract \
      "${incomplete_identity}" signed TESTTEAM1 com.inflow.desktop

  echo "release archive contract self-test passed"
}

SELF_TEST=0
if [ "$#" -eq 1 ] && [ "$1" = "--self-test" ]; then
  SELF_TEST=1
elif [ "$#" -eq 2 ] && [ "$1" = "--local" ]; then
  LOCAL_VALIDATION=1
  shift
else
  LOCAL_VALIDATION=0
fi

TEMPORARY_ROOT="$(/usr/bin/mktemp -d -t inflow-release-archive-verification)"
case "${TEMPORARY_ROOT}" in
  /private/tmp/* | /private/var/* | /tmp/* | /var/*) ;;
  *)
    echo "error: refusing unexpected temporary path: ${TEMPORARY_ROOT}" >&2
    exit 1
    ;;
esac
trap '/bin/rm -rf -- "${TEMPORARY_ROOT}"' EXIT HUP INT TERM

if [ "${SELF_TEST}" -eq 1 ]; then
  run_contract_self_test
  exit 0
fi

if [ "$#" -ne 1 ]; then
  echo "usage: $0 [--local] /path/to/Inflow.xcarchive | $0 --self-test" >&2
  exit 64
fi

ARCHIVE_PATH="$1"
APP_PATH="${ARCHIVE_PATH}/Products/Applications/Inflow.app"
BINARY_PATH="${APP_PATH}/Contents/MacOS/Inflow"
INFO_PATH="${APP_PATH}/Contents/Info.plist"
PRIVACY_MANIFEST_PATH="${APP_PATH}/Contents/Resources/PrivacyInfo.xcprivacy"
DSYM_PATH="${ARCHIVE_PATH}/dSYMs/Inflow.app.dSYM"
DSYM_BINARY_PATH="${DSYM_PATH}/Contents/Resources/DWARF/Inflow"

if [ ! -f "${BINARY_PATH}" ] || [ ! -f "${INFO_PATH}" ] \
  || [ ! -f "${PRIVACY_MANIFEST_PATH}" ] || [ ! -f "${DSYM_BINARY_PATH}" ]
then
  echo "error: archive does not contain the Inflow app, privacy manifest, and dSYM" >&2
  exit 1
fi

verify_zero_collection_privacy_manifest "${PRIVACY_MANIFEST_PATH}"

if /usr/bin/plutil -extract InflowAnonymousUsageEndpoint raw "${INFO_PATH}" >/dev/null 2>&1; then
  echo "error: launch Info.plist must not contain an anonymous-usage endpoint" >&2
  exit 1
fi

RELEASE_PROFILE="$(
  /usr/bin/plutil -extract InflowReleaseProfile raw "${INFO_PATH}" 2>/dev/null || true
)"
MANUAL_UPDATE_URL="$(
  /usr/bin/plutil -extract InflowManualUpdateURL raw "${INFO_PATH}" 2>/dev/null || true
)"
SOURCE_HEAD="$(
  /usr/bin/plutil -extract InflowSourceHead raw "${INFO_PATH}" 2>/dev/null || true
)"
if [ "${LOCAL_VALIDATION}" -eq 1 ]; then
  if [ "${RELEASE_PROFILE}" != "development-preview" ]; then
    echo "error: local archive must identify only as development-preview" >&2
    exit 1
  fi
  if [ -n "${MANUAL_UPDATE_URL}" ]; then
    echo "error: local archive must not carry a release update URL" >&2
    exit 1
  fi
  if [ "${SOURCE_HEAD}" != "development-unbound" ]; then
    echo "error: local archive must not impersonate a source-bound release" >&2
    exit 1
  fi
else
  if [ "${RELEASE_PROFILE}" != "signed-preview" ]; then
    echo "error: Developer ID archive is missing the signed-preview release profile" >&2
    exit 1
  fi
  if ! valid_manual_update_url "${MANUAL_UPDATE_URL}"; then
    echo "error: Developer ID archive has no valid fixed manual-update HTTPS URL" >&2
    exit 1
  fi
  if ! valid_git_object_id "${SOURCE_HEAD}"; then
    echo "error: Developer ID archive does not bind a full lowercase source HEAD" >&2
    exit 1
  fi
fi

for TELEMETRY_MARKER in \
  AnonymousUsageDataController \
  InflowAnonymousUsageEndpoint \
  privacy.anonymousUsage.enabled
do
  if /usr/bin/strings "${BINARY_PATH}" | /usr/bin/grep -Fq "${TELEMETRY_MARKER}"; then
    echo "error: launch executable contains telemetry path: ${TELEMETRY_MARKER}" >&2
    exit 1
  fi
done

ARCHITECTURES="$(/usr/bin/lipo -archs "${BINARY_PATH}")"
if [ "${ARCHITECTURES}" != "arm64" ]; then
  echo "error: expected only arm64, found ${ARCHITECTURES}" >&2
  exit 1
fi

BINARY_BUILD_INFO="$(/usr/bin/xcrun vtool -show-build "${BINARY_PATH}")"
BINARY_PLATFORM="$(echo "${BINARY_BUILD_INFO}" | /usr/bin/awk '$1 == "platform" { print $2; exit }')"
BINARY_MINIMUM_SYSTEM="$(echo "${BINARY_BUILD_INFO}" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
if [ "${BINARY_PLATFORM}" != "MACOS" ] || [ "${BINARY_MINIMUM_SYSTEM}" != "14.0" ]; then
  echo "error: expected a macOS 14.0 Mach-O, found ${BINARY_PLATFORM} ${BINARY_MINIMUM_SYSTEM}" >&2
  exit 1
fi

MINIMUM_SYSTEM="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "${INFO_PATH}")"
if [ "${MINIMUM_SYSTEM}" != "14.0" ]; then
  echo "error: expected macOS 14.0 minimum, found ${MINIMUM_SYSTEM}" >&2
  exit 1
fi

MARKETING_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "${INFO_PATH}")"
BUILD_VERSION="$(/usr/bin/plutil -extract CFBundleVersion raw "${INFO_PATH}")"
BUNDLE_IDENTIFIER="$(/usr/bin/plutil -extract CFBundleIdentifier raw "${INFO_PATH}")"
if [ -z "${MARKETING_VERSION}" ] || [ -z "${BUILD_VERSION}" ]; then
  echo "error: archive is missing version metadata" >&2
  exit 1
fi
if [ "${BUNDLE_IDENTIFIER}" != "com.inflow.desktop" ]; then
  echo "error: unexpected bundle identifier: ${BUNDLE_IDENTIFIER}" >&2
  exit 1
fi

UNEXPECTED_BUNDLE_ARTIFACT="$({
  /usr/bin/find "${APP_PATH}" \
    \( -name '*.xctest' -o -name '*.swiftmodule' -o -name '*.swiftinterface' \
      -o -name '*.a' -o -name '*.dSYM' \) \
    -print -quit
} 2>/dev/null)"
if [ -n "${UNEXPECTED_BUNDLE_ARTIFACT}" ]; then
  echo "error: archived app contains a development artifact: ${UNEXPECTED_BUNDLE_ARTIFACT}" >&2
  exit 1
fi

UNEXPECTED_EXECUTABLE="$({
  /usr/bin/find "${APP_PATH}" -type f -perm -111 ! -path "${BINARY_PATH}" -print -quit
} 2>/dev/null)"
if [ -n "${UNEXPECTED_EXECUTABLE}" ]; then
  echo "error: archived app contains an unexpected executable: ${UNEXPECTED_EXECUTABLE}" >&2
  exit 1
fi

/usr/bin/otool -L "${BINARY_PATH}" \
  | /usr/bin/awk 'NR > 1 { print $1 }' \
  | while IFS= read -r DEPENDENCY; do
      case "${DEPENDENCY}" in
        /System/Library/* | /usr/lib/*) ;;
        *)
          echo "error: release executable has a non-system dependency: ${DEPENDENCY}" >&2
          exit 1
          ;;
      esac
    done

BINARY_DWARF_ID="$(
  /usr/bin/xcrun dwarfdump --uuid "${BINARY_PATH}" \
    | /usr/bin/awk '{ print $2 " " $3 }'
)"
DSYM_DWARF_ID="$(
  /usr/bin/xcrun dwarfdump --uuid "${DSYM_PATH}" \
    | /usr/bin/awk '{ print $2 " " $3 }'
)"
if [ -z "${BINARY_DWARF_ID}" ] || [ "${BINARY_DWARF_ID}" != "${DSYM_DWARF_ID}" ]; then
  echo "error: archived app and dSYM UUIDs do not match" >&2
  exit 1
fi

SIGNATURE_DESCRIPTION="unsigned local archive"
SIGNING_TEAM_ID=""
ENTITLEMENT_VALIDATION_MODE="local"
if /usr/bin/codesign --verify --deep --strict "${APP_PATH}" >/dev/null 2>&1; then
  SIGNATURE_DETAILS="$(/usr/bin/codesign -dvv "${APP_PATH}" 2>&1)"
  if ! echo "${SIGNATURE_DETAILS}" | /usr/bin/grep -Eq 'flags=.*runtime'; then
    echo "error: archived app is missing hardened runtime" >&2
    exit 1
  fi
  if [ "${LOCAL_VALIDATION}" -ne 1 ] \
    && echo "${SIGNATURE_DETAILS}" | /usr/bin/grep -q 'Signature=adhoc'
  then
    echo "error: archived app has only an ad-hoc signature" >&2
    exit 1
  fi
  SIGNING_AUTHORITY="$(
    echo "${SIGNATURE_DETAILS}" \
      | /usr/bin/awk -F= '$1 == "Authority" { print $2; exit }'
  )"
  SIGNING_TEAM_ID="$(
    echo "${SIGNATURE_DETAILS}" \
      | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }'
  )"
  if [ "${LOCAL_VALIDATION}" -ne 1 ]; then
    case "${SIGNING_AUTHORITY}" in
      "Developer ID Application:"*) ;;
      *)
        echo "error: launch profile requires Developer ID Application signing: ${SIGNING_AUTHORITY:-none}" >&2
        exit 1
        ;;
    esac
    case "${SIGNING_TEAM_ID}" in
      *[!A-Za-z0-9]* | '')
        echo "error: Developer ID signature has no valid Team ID" >&2
        exit 1
        ;;
    esac
    case "${SIGNING_AUTHORITY}" in
      *"(${SIGNING_TEAM_ID})") ;;
      *)
        echo "error: Developer ID authority and Team ID do not match" >&2
        exit 1
        ;;
    esac
    SIGNATURE_TIMESTAMP="$(
      echo "${SIGNATURE_DETAILS}" \
        | /usr/bin/awk -F= '$1 == "Timestamp" { print $2; exit }'
    )"
    if [ -z "${SIGNATURE_TIMESTAMP}" ] || [ "${SIGNATURE_TIMESTAMP}" = "none" ]; then
      echo "error: Developer ID signature is missing a secure timestamp" >&2
      exit 1
    fi
  fi
  if [ -n "${SIGNING_TEAM_ID}" ]; then
    ENTITLEMENT_VALIDATION_MODE="signed"
  fi

  SIGNED_ENTITLEMENTS="${TEMPORARY_ROOT}/signed-entitlements.plist"
  if ! /usr/bin/codesign -d --entitlements - --xml "${APP_PATH}" \
      >"${SIGNED_ENTITLEMENTS}" 2>/dev/null
  then
    echo "error: could not extract signed entitlements" >&2
    exit 1
  fi
  if [ ! -s "${SIGNED_ENTITLEMENTS}" ]; then
    echo "error: signed entitlement plist is missing" >&2
    exit 1
  fi
  ENTITLEMENTS_PATH="${SIGNED_ENTITLEMENTS}"
  SIGNATURE_DESCRIPTION="signed hardened runtime (${SIGNING_AUTHORITY})"
elif [ "${LOCAL_VALIDATION}" -eq 1 ]; then
  ENTITLEMENTS_PATH="${SCRIPT_DIRECTORY}/../macos/Inflow/Resources/Inflow.entitlements"
else
  echo "error: archived app is not validly distribution signed" >&2
  exit 1
fi

verify_entitlement_contract \
  "${ENTITLEMENTS_PATH}" \
  "${ENTITLEMENT_VALIDATION_MODE}" \
  "${SIGNING_TEAM_ID}" \
  "${BUNDLE_IDENTIFIER}"

if /usr/bin/strings "${BINARY_PATH}" \
  | /usr/bin/grep -E '/Users/[^/[:space:]]+/|/home/[^/[:space:]]+/|/private/var/folders/|\.cargo/registry/' \
  >/dev/null
then
  echo "error: release executable contains a private build path" >&2
  exit 1
fi

echo "verified Inflow ${MARKETING_VERSION} (${BUILD_VERSION}), arm64, macOS ${MINIMUM_SYSTEM}+, system-only dynamic dependencies, dSYM ${BINARY_DWARF_ID}, ${SIGNATURE_DESCRIPTION}"
