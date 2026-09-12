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

XCODE_ARCHS="${ARCHS:-${CURRENT_ARCH:-}}"
if [ -z "${XCODE_ARCHS}" ] || [ "${XCODE_ARCHS}" = "undefined_arch" ]; then
  XCODE_ARCHS="$(uname -m)"
fi

set --
for XCODE_ARCH in ${XCODE_ARCHS}; do
  case "${XCODE_ARCH}" in
    arm64)
      RUST_TARGET="aarch64-apple-darwin"
      ;;
    x86_64)
      RUST_TARGET="x86_64-apple-darwin"
      ;;
    *)
      echo "error: unsupported macOS architecture: ${XCODE_ARCH}" >&2
      exit 1
      ;;
  esac

  "${CARGO_EXECUTABLE}" build \
    --manifest-path "${CORE_MANIFEST}" \
    --locked \
    --target "${RUST_TARGET}" \
    ${CARGO_PROFILE_ARGUMENT}

  set -- "$@" "${CARGO_TARGET_OUTPUT}/${RUST_TARGET}/${CARGO_OUTPUT_PROFILE}/libinflow_core.a"
done

mkdir -p "${BUILT_PRODUCTS_DIR}"
if [ "$#" -eq 1 ]; then
  cp "$1" "${BUILT_PRODUCTS_DIR}/libinflow_core.a"
else
  xcrun lipo -create "$@" -output "${BUILT_PRODUCTS_DIR}/libinflow_core.a"
fi
