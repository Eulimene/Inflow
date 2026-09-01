#!/bin/sh

set -eu

SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CODE_ROOT="$(CDPATH= cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
CORPUS_PATH="${1:-${CODE_ROOT}/quality/extensions/extension-contract-negative-corpus-v1.json}"

case "${CORPUS_PATH}" in
  /*) ;;
  *) CORPUS_PATH="$(pwd)/${CORPUS_PATH}" ;;
esac

[ -f "${CORPUS_PATH}" ] || {
  echo "error: extension contract corpus does not exist: ${CORPUS_PATH}" >&2
  exit 1
}

EXTENSION_CONTRACT_MODULE_CACHE="/private/tmp/inflow-extension-contract-module-cache"
/bin/mkdir -p "${EXTENSION_CONTRACT_MODULE_CACHE}"
export SWIFT_MODULECACHE_PATH="${EXTENSION_CONTRACT_MODULE_CACHE}"
export CLANG_MODULE_CACHE_PATH="${EXTENSION_CONTRACT_MODULE_CACHE}"

exec /usr/bin/xcrun swift \
  "${SCRIPT_DIRECTORY}/verify-extension-contracts.swift" \
  "${CORPUS_PATH}"
