#!/bin/sh
set -eu

SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIRECTORY="$(dirname -- "${SCRIPT_DIRECTORY}")"
if command -v cargo >/dev/null 2>&1; then
  CARGO_EXECUTABLE="$(command -v cargo)"
elif [ -x "${CARGO_HOME:-${HOME}/.cargo}/bin/cargo" ]; then
  CARGO_EXECUTABLE="${CARGO_HOME:-${HOME}/.cargo}/bin/cargo"
else
  echo "error: cargo not found; install the toolchain from rust-toolchain.toml" >&2
  exit 1
fi

# Build-time tool only; never linked into the app or invoked when opening a file.
export CARGO_TARGET_DIR="${DERIVED_FILE_DIR:-${PROJECT_DIRECTORY}/build}/theme-tools"
cd "${PROJECT_DIRECTORY}"
"${CARGO_EXECUTABLE}" run --quiet --manifest-path xtask/Cargo.toml --locked -- themes
