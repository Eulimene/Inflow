#!/bin/sh

set -eu

LOCAL_VALIDATION=0
if [ "$#" -eq 2 ] && [ "$1" = "--local" ]; then
  LOCAL_VALIDATION=1
  shift
fi

if [ "$#" -ne 1 ]; then
  echo "usage: $0 [--local] /path/to/Inflow.xcarchive" >&2
  exit 64
fi

ARCHIVE_PATH="$1"
SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
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

if ! /usr/bin/plutil -lint "${PRIVACY_MANIFEST_PATH}" >/dev/null; then
  echo "error: archived privacy manifest is invalid" >&2
  exit 1
fi

privacy_value() {
  /usr/bin/plutil -extract "$1" raw "${PRIVACY_MANIFEST_PATH}" 2>/dev/null || true
}

if [ "$(privacy_value NSPrivacyTracking)" != "false" ]; then
  echo "error: privacy manifest must disable tracking" >&2
  exit 1
fi
if [ -n "$(privacy_value NSPrivacyTrackingDomains.0)" ]; then
  echo "error: privacy manifest declares a tracking domain" >&2
  exit 1
fi
if [ -n "$(privacy_value NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType)" ]; then
  echo "error: privacy manifest declares an unexpected accessed API type" >&2
  exit 1
fi

EXPECTED_PRIVACY_TYPES="NSPrivacyCollectedDataTypeProductInteraction
NSPrivacyCollectedDataTypePerformanceData
NSPrivacyCollectedDataTypeOtherDiagnosticData
NSPrivacyCollectedDataTypeOtherDataTypes"
PRIVACY_INDEX=0
echo "${EXPECTED_PRIVACY_TYPES}" | while IFS= read -r EXPECTED_PRIVACY_TYPE; do
  PRIVACY_PREFIX="NSPrivacyCollectedDataTypes.${PRIVACY_INDEX}"
  if [ "$(privacy_value "${PRIVACY_PREFIX}.NSPrivacyCollectedDataType")" \
      != "${EXPECTED_PRIVACY_TYPE}" ] \
    || [ "$(privacy_value "${PRIVACY_PREFIX}.NSPrivacyCollectedDataTypeLinked")" \
      != "false" ] \
    || [ "$(privacy_value "${PRIVACY_PREFIX}.NSPrivacyCollectedDataTypeTracking")" \
      != "false" ] \
    || [ "$(privacy_value "${PRIVACY_PREFIX}.NSPrivacyCollectedDataTypePurposes.0")" \
      != "NSPrivacyCollectedDataTypePurposeAnalytics" ] \
    || [ -n "$(privacy_value "${PRIVACY_PREFIX}.NSPrivacyCollectedDataTypePurposes.1")" ]
  then
    echo "error: privacy manifest collection contract does not match ${EXPECTED_PRIVACY_TYPE}" >&2
    exit 1
  fi
  PRIVACY_INDEX=$((PRIVACY_INDEX + 1))
done

if [ -n "$(privacy_value NSPrivacyCollectedDataTypes.4.NSPrivacyCollectedDataType)" ]; then
  echo "error: privacy manifest declares an unexpected collected data type" >&2
  exit 1
fi

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
if [ -z "${MARKETING_VERSION}" ] || [ -z "${BUILD_VERSION}" ]; then
  echo "error: archive is missing version metadata" >&2
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

require_true_entitlement() {
  entitlement_path="$1"
  entitlement_key="$2"
  entitlement_value="$(
    /usr/libexec/PlistBuddy -c "Print :${entitlement_key}" "${entitlement_path}" 2>/dev/null \
      || true
  )"
  if [ "${entitlement_value}" != "true" ]; then
    echo "error: required entitlement is missing: ${entitlement_key}" >&2
    exit 1
  fi
}

SIGNATURE_DESCRIPTION="unsigned local archive"
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

  SIGNED_ENTITLEMENTS="$(/usr/bin/mktemp -t inflow-entitlements).plist"
  trap '/bin/rm -f "${SIGNED_ENTITLEMENTS}"' EXIT HUP INT TERM
  /usr/bin/codesign -d --entitlements :- "${APP_PATH}" \
    >"${SIGNED_ENTITLEMENTS}" 2>/dev/null
  ENTITLEMENTS_PATH="${SIGNED_ENTITLEMENTS}"
  SIGNATURE_DESCRIPTION="signed hardened runtime"
elif [ "${LOCAL_VALIDATION}" -eq 1 ]; then
  ENTITLEMENTS_PATH="${SCRIPT_DIRECTORY}/../macos/Inflow/Resources/Inflow.entitlements"
else
  echo "error: archived app is not validly distribution signed" >&2
  exit 1
fi

for ENTITLEMENT_KEY in \
  com.apple.security.app-sandbox \
  com.apple.security.files.user-selected.read-write \
  com.apple.security.files.bookmarks.app-scope \
  com.apple.security.network.client
do
  require_true_entitlement "${ENTITLEMENTS_PATH}" "${ENTITLEMENT_KEY}"
done

if /usr/bin/strings "${BINARY_PATH}" \
  | /usr/bin/grep -E '/Users/|/home/|/private/var/folders/|\.cargo/registry/' \
  >/dev/null
then
  echo "error: release executable contains a private build path" >&2
  exit 1
fi

echo "verified Inflow ${MARKETING_VERSION} (${BUILD_VERSION}), arm64, macOS ${MINIMUM_SYSTEM}+, system-only dynamic dependencies, dSYM ${BINARY_DWARF_ID}, ${SIGNATURE_DESCRIPTION}"
