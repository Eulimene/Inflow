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
DSYM_PATH="${ARCHIVE_PATH}/dSYMs/Inflow.app.dSYM"
DSYM_BINARY_PATH="${DSYM_PATH}/Contents/Resources/DWARF/Inflow"

if [ ! -f "${BINARY_PATH}" ] || [ ! -f "${INFO_PATH}" ] || [ ! -f "${DSYM_BINARY_PATH}" ]; then
  echo "error: archive does not contain the Inflow app and its dSYM" >&2
  exit 1
fi

ARCHITECTURES="$(/usr/bin/lipo -archs "${BINARY_PATH}")"
if [ "${ARCHITECTURES}" != "arm64" ]; then
  echo "error: expected only arm64, found ${ARCHITECTURES}" >&2
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

echo "verified Inflow ${MARKETING_VERSION} (${BUILD_VERSION}), arm64, macOS ${MINIMUM_SYSTEM}+, dSYM ${BINARY_DWARF_ID}, ${SIGNATURE_DESCRIPTION}"
