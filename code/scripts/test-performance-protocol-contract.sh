#!/bin/sh

set -eu

SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VERIFIER="${SCRIPT_DIRECTORY}/verify-performance-protocol.sh"

"${VERIFIER}" --check-os-version 14.0 14.0 >/dev/null

if "${VERIFIER}" --check-os-version 14.1 14.0 >/dev/null 2>&1; then
  echo "error: macOS 14.1 was accepted for the exact 14.0 performance target" >&2
  exit 1
fi

if "${VERIFIER}" --check-os-version 14 14.0 >/dev/null 2>&1; then
  echo "error: major-only macOS 14 evidence was accepted for the exact 14.0 target" >&2
  exit 1
fi

echo "verified exact macOS 14.0 performance protocol matching"
