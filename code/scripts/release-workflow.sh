#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Inflow direct-distribution release workflow

Usage:
  release-workflow.sh check
  release-workflow.sh candidate [output-root]
  release-workflow.sh verify-local-archive ARCHIVE
  release-workflow.sh verify-zip ZIP
  release-workflow.sh developer-id-archive TEAM_ID [output-root]
  release-workflow.sh notarize ARCHIVE KEYCHAIN_PROFILE [output-root]
  release-workflow.sh verify-notarized-app APP
  release-workflow.sh open-archive ARCHIVE

Commands:
  check
      Run every repository-controlled launch gate with a temporary unsigned archive.

  candidate [output-root]
      Run every gate once, keep a fresh unsigned local archive, compress it, and
      print/write its SHA-256. The default root is code/build/releases.

  verify-local-archive ARCHIVE
      Recheck a retained unsigned local archive without rebuilding it.

  verify-zip ZIP
      Check ZIP structure and, when ZIP.sha256 exists, verify its SHA-256.

  developer-id-archive TEAM_ID [output-root]
      Build a fresh Developer ID archive using an installed matching certificate,
      then run the full signed-archive launch gate. The default root is
      code/build/releases.

  notarize ARCHIVE KEYCHAIN_PROFILE [output-root]
      Verify a Developer ID archive, copy its app, submit it with notarytool,
      save the notary result and log, staple the ticket, assess it with Gatekeeper,
      then create the final ZIP and SHA-256. The Keychain profile must already
      exist (create it with `xcrun notarytool store-credentials`).

  verify-notarized-app APP
      Verify Developer ID signature, hardened runtime, stapled ticket, and
      Gatekeeper acceptance for an exported app.

  open-archive ARCHIVE
      Open the Inflow app contained in an archive for manual acceptance testing.

This script never accepts Apple credentials or passwords and never replaces an
existing archive/output directory.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

require_argument_count() {
  actual="$1"
  minimum="$2"
  maximum="$3"
  if [ "${actual}" -lt "${minimum}" ] || [ "${actual}" -gt "${maximum}" ]; then
    usage >&2
    exit 64
  fi
}

make_absolute_directory() {
  directory="$1"
  /bin/mkdir -p "${directory}"
  (CDPATH= cd -- "${directory}" && pwd)
}

fresh_output_directory() {
  root="$1"
  label="$2"
  timestamp="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
  output_directory="${root}/${label}-${timestamp}"
  [ ! -e "${output_directory}" ] \
    || die "refusing to replace existing output: ${output_directory}"
  /bin/mkdir -p "${output_directory}"
  echo "${output_directory}"
}

archive_app_path() {
  echo "$1/Products/Applications/Inflow.app"
}

signature_details() {
  /usr/bin/codesign -dvv "$1" 2>&1
}

require_developer_id_signature() {
  app_path="$1"
  expected_team_id="${2:-}"
  [ -d "${app_path}" ] || die "Inflow app does not exist: ${app_path}"
  /usr/bin/codesign --verify --deep --strict "${app_path}" \
    || die "Developer ID signature verification failed"
  details="$(signature_details "${app_path}")"
  signing_authority="$(
    echo "${details}" | /usr/bin/awk -F= '$1 == "Authority" { print $2; exit }'
  )"
  case "${signing_authority}" in
    "Developer ID Application:"*) ;;
    *) die "app is not signed with a Developer ID Application identity" ;;
  esac
  if [ -n "${expected_team_id}" ]; then
    case "${signing_authority}" in
      *"(${expected_team_id})") ;;
      *) die "Developer ID signature does not belong to team ${expected_team_id}" ;;
    esac
  fi
  echo "${details}" | /usr/bin/grep -Eq 'flags=.*runtime' \
    || die "app signature is missing hardened runtime"
  signature_timestamp="$(
    echo "${details}" | /usr/bin/awk -F= '$1 == "Timestamp" { print $2; exit }'
  )"
  [ -n "${signature_timestamp}" ] && [ "${signature_timestamp}" != "none" ] \
    || die "app signature is missing a secure timestamp"
}

verify_notarized_app() {
  app_path="$1"
  require_developer_id_signature "${app_path}"
  /usr/bin/xcrun stapler validate "${app_path}"
  /usr/sbin/spctl --assess --type execute --verbose=4 "${app_path}"
}

write_zip_and_hash() {
  source_path="$1"
  zip_path="$2"
  [ ! -e "${zip_path}" ] || die "refusing to replace existing ZIP: ${zip_path}"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "${source_path}" "${zip_path}"
  /usr/bin/unzip -tq "${zip_path}"
  hash_value="$(/usr/bin/shasum -a 256 "${zip_path}" | /usr/bin/awk '{ print $1 }')"
  printf '%s  %s\n' "${hash_value}" "$(/usr/bin/basename "${zip_path}")" \
    >"${zip_path}.sha256"
  echo "ZIP: ${zip_path}"
  echo "SHA-256: ${hash_value}"
  echo "checksum file: ${zip_path}.sha256"
}

verify_zip() {
  zip_path="$1"
  [ -f "${zip_path}" ] || die "ZIP does not exist: ${zip_path}"
  /usr/bin/unzip -tq "${zip_path}"
  actual_hash="$(/usr/bin/shasum -a 256 "${zip_path}" | /usr/bin/awk '{ print $1 }')"
  checksum_path="${zip_path}.sha256"
  if [ -f "${checksum_path}" ]; then
    expected_hash="$(/usr/bin/awk 'NR == 1 { print $1 }' "${checksum_path}")"
    [ -n "${expected_hash}" ] && [ "${actual_hash}" = "${expected_hash}" ] \
      || die "SHA-256 does not match ${checksum_path}"
    echo "verified checksum file: ${checksum_path}"
  else
    echo "warning: checksum file is absent: ${checksum_path}" >&2
  fi
  echo "verified ZIP SHA-256: ${actual_hash}"
}

SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CODE_ROOT="$(CDPATH= cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
PROJECT_PATH="${CODE_ROOT}/Inflow.xcodeproj"
VERIFY_LAUNCH="${SCRIPT_DIRECTORY}/verify-launch.sh"
VERIFY_ARCHIVE="${SCRIPT_DIRECTORY}/verify-release-archive.sh"
DEFAULT_OUTPUT_ROOT="${CODE_ROOT}/build/releases"

[ "$#" -ge 1 ] || {
  usage >&2
  exit 64
}

command_name="$1"
shift

case "${command_name}" in
  help | --help | -h)
    require_argument_count "$#" 0 0
    usage
    ;;

  check)
    require_argument_count "$#" 0 0
    exec "${VERIFY_LAUNCH}" --local
    ;;

  candidate)
    require_argument_count "$#" 0 1
    require_command xcodebuild
    output_root="$(make_absolute_directory "${1:-${DEFAULT_OUTPUT_ROOT}}")"
    output_directory="$(fresh_output_directory "${output_root}" Inflow-local)"
    archive_path="${output_directory}/Inflow.xcarchive"
    INFLOW_LOCAL_ARCHIVE_PATH="${archive_path}" \
      "${VERIFY_LAUNCH}" --local
    write_zip_and_hash "${archive_path}" "${output_directory}/Inflow.xcarchive.zip"
    echo "archive: ${archive_path}"
    echo "local candidate passed every automated gate; it is not signed for distribution"
    ;;

  verify-local-archive)
    require_argument_count "$#" 1 1
    "${VERIFY_ARCHIVE}" --local "$1"
    ;;

  verify-zip)
    require_argument_count "$#" 1 1
    verify_zip "$1"
    ;;

  developer-id-archive)
    require_argument_count "$#" 1 2
    require_command xcodebuild
    team_id="$1"
    output_root="$(make_absolute_directory "${2:-${DEFAULT_OUTPUT_ROOT}}")"
    case "${team_id}" in
      *[!A-Za-z0-9]* | '') die "TEAM_ID must contain only letters and digits" ;;
    esac
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/grep -E "Developer ID Application: .+ \\(${team_id}\\)" >/dev/null \
      || die "no Developer ID Application certificate for team ${team_id} is installed"
    output_directory="$(fresh_output_directory "${output_root}" Inflow-developer-id)"
    archive_path="${output_directory}/Inflow.xcarchive"
    /usr/bin/xcodebuild \
      -project "${PROJECT_PATH}" \
      -scheme Inflow \
      -configuration Release \
      -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath "${output_directory}/DerivedData" \
      -archivePath "${archive_path}" \
      DEVELOPMENT_TEAM="${team_id}" \
      CODE_SIGN_STYLE=Manual \
      'CODE_SIGN_IDENTITY=Developer ID Application' \
      archive
    require_developer_id_signature "$(archive_app_path "${archive_path}")" "${team_id}"
    "${VERIFY_LAUNCH}" --signed-archive "${archive_path}"
    echo "Developer ID archive: ${archive_path}"
    echo "next: $0 notarize '${archive_path}' KEYCHAIN_PROFILE"
    ;;

  notarize)
    require_argument_count "$#" 2 3
    archive_path="$1"
    keychain_profile="$2"
    [ -d "${archive_path}" ] || die "archive does not exist: ${archive_path}"
    output_root="$(make_absolute_directory "${3:-${DEFAULT_OUTPUT_ROOT}}")"
    archived_app="$(archive_app_path "${archive_path}")"
    require_developer_id_signature "${archived_app}"
    "${VERIFY_LAUNCH}" --signed-archive "${archive_path}"

    output_directory="$(fresh_output_directory "${output_root}" Inflow-notarized)"
    staged_app="${output_directory}/Inflow.app"
    submission_zip="${output_directory}/Inflow-notary-submission.zip"
    final_zip="${output_directory}/Inflow-notarized.zip"
    result_path="${output_directory}/notary-result.json"
    log_path="${output_directory}/notary-log.json"

    /usr/bin/ditto "${archived_app}" "${staged_app}"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
      "${staged_app}" "${submission_zip}"
    /usr/bin/xcrun notarytool submit "${submission_zip}" \
      --keychain-profile "${keychain_profile}" \
      --wait \
      --output-format json >"${result_path}"
    submission_status="$(/usr/bin/plutil -extract status raw "${result_path}")"
    submission_id="$(/usr/bin/plutil -extract id raw "${result_path}")"
    /usr/bin/xcrun notarytool log "${submission_id}" \
      --keychain-profile "${keychain_profile}" "${log_path}"
    [ "${submission_status}" = "Accepted" ] \
      || die "notarization was not accepted; inspect ${log_path}"

    /usr/bin/xcrun stapler staple "${staged_app}"
    verify_notarized_app "${staged_app}"
    write_zip_and_hash "${staged_app}" "${final_zip}"
    echo "notary result: ${result_path}"
    echo "notary log: ${log_path}"
    echo "notarized app: ${staged_app}"
    ;;

  verify-notarized-app)
    require_argument_count "$#" 1 1
    verify_notarized_app "$1"
    echo "verified notarized Developer ID app: $1"
    ;;

  open-archive)
    require_argument_count "$#" 1 1
    app_path="$(archive_app_path "$1")"
    [ -d "${app_path}" ] || die "Inflow app does not exist: ${app_path}"
    /usr/bin/open "${app_path}"
    ;;

  *)
    usage >&2
    exit 64
    ;;
esac
