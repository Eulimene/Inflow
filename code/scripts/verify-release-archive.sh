#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/Inflow.xcarchive" >&2
  exit 64
fi

ARCHIVE_PATH="$1"
APP_PATH="${ARCHIVE_PATH}/Products/Applications/Inflow.app"
BINARY_PATH="${APP_PATH}/Contents/MacOS/Inflow"
INFO_PATH="${APP_PATH}/Contents/Info.plist"

if [ ! -f "${BINARY_PATH}" ] || [ ! -f "${INFO_PATH}" ]; then
  echo "error: archive does not contain the Inflow app" >&2
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

if /usr/bin/strings "${BINARY_PATH}" \
  | /usr/bin/grep -E '/Users/|/home/|/private/var/folders/|\.cargo/registry/' \
  >/dev/null
then
  echo "error: release executable contains a private build path" >&2
  exit 1
fi

echo "verified Inflow ${MARKETING_VERSION} (${BUILD_VERSION}), arm64, macOS ${MINIMUM_SYSTEM}+"
