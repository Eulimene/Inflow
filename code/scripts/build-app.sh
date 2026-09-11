#!/bin/sh

set -eu

SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIRECTORY="$(dirname -- "${SCRIPT_DIRECTORY}")"
CONFIGURATION="Debug"
OPEN_AFTER_BUILD=0
CLEAN_BEFORE_BUILD=0
OUTPUT_DIRECTORY="${PROJECT_DIRECTORY}/.derivedData"

usage() {
  cat <<'EOF'
Usage: scripts/build-app.sh [--debug|--release] [--output-dir PATH] [--clean] [--open]

Build the Inflow macOS app with the repository's local Rust toolchain.

Options:
  --debug            Build the Debug configuration (default).
  --release          Build the Release configuration.
  -o, --output-dir   Store all build data below PATH (default: .derivedData).
  --clean            Clean the selected configuration before building.
  --open             Open this exact app build in a new process after success.
  -h, --help         Show this help message.
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
    -o|--output-dir)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "error: $1 requires a directory path" >&2
        usage >&2
        exit 2
      fi
      case "$2" in
        -*)
          echo "error: $1 requires a directory path, not another option" >&2
          usage >&2
          exit 2
          ;;
      esac
      OUTPUT_DIRECTORY="$2"
      shift
      ;;
    --output-dir=*)
      OUTPUT_DIRECTORY="${1#*=}"
      if [ -z "${OUTPUT_DIRECTORY}" ]; then
        echo "error: --output-dir requires a directory path" >&2
        usage >&2
        exit 2
      fi
      ;;
    --clean)
      CLEAN_BEFORE_BUILD=1
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

case "${OUTPUT_DIRECTORY}" in
  /*) ;;
  *) OUTPUT_DIRECTORY="$(pwd)/${OUTPUT_DIRECTORY}" ;;
esac

/bin/mkdir -p "${OUTPUT_DIRECTORY}"
DERIVED_DATA_PATH="$(CDPATH= cd -- "${OUTPUT_DIRECTORY}" && pwd -P)"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/Inflow.app"

echo "Building Inflow (${CONFIGURATION})..."
echo "Build directory: ${DERIVED_DATA_PATH}"

if [ "${CLEAN_BEFORE_BUILD}" -eq 1 ]; then
  echo "Cleaning previous ${CONFIGURATION} products..."
  /usr/bin/xcodebuild \
    -project "${PROJECT_DIRECTORY}/Inflow.xcodeproj" \
    -scheme Inflow \
    -configuration "${CONFIGURATION}" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    CODE_SIGNING_ALLOWED=NO \
    clean
fi

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
  /usr/bin/open -n "${APP_PATH}"
fi
