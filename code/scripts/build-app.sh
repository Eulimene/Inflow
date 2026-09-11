#!/bin/sh

set -eu

SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIRECTORY="$(dirname -- "${SCRIPT_DIRECTORY}")"
CONFIGURATION="Debug"
OPEN_AFTER_BUILD=0

usage() {
  cat <<'EOF'
Usage: scripts/build-app.sh [--debug|--release] [--open]

Build the Inflow macOS app with the repository's local Rust toolchain.

Options:
  --debug    Build the Debug configuration (default).
  --release  Build the Release configuration.
  --open     Open the app after a successful build.
  -h, --help Show this help message.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --debug)
      CONFIGURATION="Debug"
      ;;
    --release)
      CONFIGURATION="Release"
      ;;
    --open)
      OPEN_AFTER_BUILD=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

DERIVED_DATA_PATH="${PROJECT_DIRECTORY}/.derivedData"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/Inflow.app"

echo "Building Inflow (${CONFIGURATION})..."

/usr/bin/xcodebuild \
  -project "${PROJECT_DIRECTORY}/Inflow.xcodeproj" \
  -scheme Inflow \
  -configuration "${CONFIGURATION}" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [ ! -d "${APP_PATH}" ]; then
  echo "error: build completed without producing ${APP_PATH}" >&2
  exit 1
fi

echo
echo "Build succeeded: ${APP_PATH}"

if [ "${OPEN_AFTER_BUILD}" -eq 1 ]; then
  /usr/bin/open "${APP_PATH}"
fi
