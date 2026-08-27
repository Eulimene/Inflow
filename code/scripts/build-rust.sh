#!/bin/sh

set -eu

if command -v cargo >/dev/null 2>&1; then
  CARGO_EXECUTABLE="$(command -v cargo)"
elif [ -x "${CARGO_HOME:-${HOME}/.cargo}/bin/cargo" ]; then
  CARGO_EXECUTABLE="${CARGO_HOME:-${HOME}/.cargo}/bin/cargo"
else
  echo "error: cargo not found; install the toolchain from rust-toolchain.toml" >&2
  exit 1
fi

CORE_MANIFEST="${PROJECT_DIR}/core/Cargo.toml"
RUST_TARGET="aarch64-apple-darwin"
CARGO_TARGET_OUTPUT="${DERIVED_FILE_DIR}/rust-target"

export CARGO_TARGET_DIR="${CARGO_TARGET_OUTPUT}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
RUST_SOURCE_ROOT="${CARGO_HOME:-${HOME}/.cargo}"
RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${PROJECT_DIR}=inflow --remap-path-prefix=${RUST_SOURCE_ROOT}=cargo"
export RUSTFLAGS

cd "${PROJECT_DIR}"

if [ "${CONFIGURATION}" = "Release" ]; then
  CARGO_PROFILE_ARGUMENT="--release"
  CARGO_OUTPUT_PROFILE="release"
else
  CARGO_PROFILE_ARGUMENT=""
  CARGO_OUTPUT_PROFILE="debug"
fi

"${CARGO_EXECUTABLE}" build \
  --manifest-path "${CORE_MANIFEST}" \
  --locked \
  --target "${RUST_TARGET}" \
  ${CARGO_PROFILE_ARGUMENT}

mkdir -p "${BUILT_PRODUCTS_DIR}"
cp \
  "${CARGO_TARGET_OUTPUT}/${RUST_TARGET}/${CARGO_OUTPUT_PROFILE}/libinflow_core.a" \
  "${BUILT_PRODUCTS_DIR}/libinflow_core.a"
