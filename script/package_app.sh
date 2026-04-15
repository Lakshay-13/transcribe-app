#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PRODUCT_NAME="TranscribeMacApp"
APP_NAME="Transcribe"
BUNDLE_IDENTIFIER="com.lakshaychawla.transcribemacapp"
APP_VERSION="1.0.0"
APP_BUILD_NUMBER="1"
MIN_MACOS_VERSION="13.0"

DIST_DIR="${PROJECT_ROOT}/dist"
APP_BUNDLE_PATH="${DIST_DIR}/${APP_NAME}.app"
APP_CONTENTS_DIR="${APP_BUNDLE_PATH}/Contents"
APP_MACOS_DIR="${APP_CONTENTS_DIR}/MacOS"
APP_RESOURCES_DIR="${APP_CONTENTS_DIR}/Resources"
APP_BIN_DIR="${APP_RESOURCES_DIR}/bin"
APP_LIB_DIR="${APP_RESOURCES_DIR}/lib"
APP_EXECUTABLE_PATH="${APP_MACOS_DIR}/${PRODUCT_NAME}"
APP_ICON_PATH="${APP_RESOURCES_DIR}/AppIcon.icns"
INFO_PLIST_PATH="${APP_CONTENTS_DIR}/Info.plist"
APP_FFMPEG_PATH="${APP_BIN_DIR}/ffmpeg"
RELEASE_BINARY="${PROJECT_ROOT}/.build/release/${PRODUCT_NAME}"
DMG_PATH="${DIST_DIR}/${APP_NAME}-Installer.dmg"
PKG_PATH="${DIST_DIR}/${APP_NAME}-Installer.pkg"
ROOT_DMG_PATH="${PROJECT_ROOT}/${APP_NAME}-Installer.dmg"
ROOT_PKG_PATH="${PROJECT_ROOT}/${APP_NAME}-Installer.pkg"
PKG_IDENTIFIER="${BUNDLE_IDENTIFIER}.installer"
DMG_STAGE_DIR="${DIST_DIR}/dmg-stage"

TEMP_ITEMS=()
DEPENDENCY_SEEN_FILE=""

log() {
  printf '[package_app] %s\n' "$1"
}

fail() {
  printf '[package_app] ERROR: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  local item
  if [[ "${#TEMP_ITEMS[@]}" -eq 0 ]]; then
    return 0
  fi

  for item in "${TEMP_ITEMS[@]}"; do
    if [[ -e "${item}" ]]; then
      rm -rf "${item}"
    fi
  done
}

trap cleanup EXIT

resolve_ffmpeg() {
  local candidate

  if [[ -n "${TRANSCIBE_FFMPEG_PATH:-}" ]]; then
    if [[ -x "${TRANSCIBE_FFMPEG_PATH}" ]]; then
      printf '%s\n' "${TRANSCIBE_FFMPEG_PATH}"
      return 0
    fi
    fail "TRANSCIBE_FFMPEG_PATH is set but not executable: ${TRANSCIBE_FFMPEG_PATH}"
  fi

  for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  if command -v ffmpeg >/dev/null 2>&1; then
    candidate="$(command -v ffmpeg)"
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi

  fail "ffmpeg not found. Set TRANSCIBE_FFMPEG_PATH or install ffmpeg (brew install ffmpeg)."
}

canonicalize_path() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    (
      cd "$(dirname "${path}")" && \
      printf '%s/%s\n' "$(pwd -P)" "$(basename "${path}")"
    )
  else
    printf '%s\n' "${path}"
  fi
}

list_binary_deps() {
  local binary="$1"
  otool -L "${binary}" | tail -n +2 | awk '{print $1}'
}

list_binary_rpaths() {
  local binary="$1"
  otool -l "${binary}" | awk '
    $1=="cmd" && $2=="LC_RPATH" { capture=1; next }
    capture && $1=="path" { print $2; capture=0 }
  '
}

is_system_library() {
  local dep="$1"
  [[ "${dep}" == /System/* || "${dep}" == /usr/lib/* ]]
}

is_seen_dependency() {
  local candidate="$1"
  [[ -n "${DEPENDENCY_SEEN_FILE}" ]] || return 1
  grep -Fqx -- "${candidate}" "${DEPENDENCY_SEEN_FILE}" 2>/dev/null
}

mark_seen_dependency() {
  local candidate="$1"
  printf '%s\n' "${candidate}" >> "${DEPENDENCY_SEEN_FILE}"
}

resolve_dependency_path() {
  local dep="$1"
  local from_binary="$2"
  local ffmpeg_source="$3"
  local from_dir
  local candidate
  local suffix
  local rpath

  from_dir="$(dirname "${from_binary}")"

  case "${dep}" in
    /System/*|/usr/lib/*)
      return 1
      ;;
    /*)
      [[ -e "${dep}" ]] && { printf '%s\n' "${dep}"; return 0; }
      ;;
    @loader_path/*)
      candidate="${dep/@loader_path/${from_dir}}"
      [[ -e "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
      ;;
    @executable_path/*)
      candidate="${dep/@executable_path/${from_dir}}"
      [[ -e "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
      ;;
    @rpath/*)
      suffix="${dep#@rpath/}"

      while IFS= read -r rpath; do
        [[ -n "${rpath}" ]] || continue
        candidate="${rpath/@loader_path/${from_dir}}"
        candidate="${candidate/@executable_path/${from_dir}}"
        [[ "${candidate}" == @* ]] && continue
        candidate="${candidate%/}/${suffix}"
        [[ -e "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
      done < <(list_binary_rpaths "${from_binary}")

      for candidate in \
        "${from_dir}/../lib/${suffix}" \
        "$(dirname "${ffmpeg_source}")/../lib/${suffix}" \
        "/opt/homebrew/lib/${suffix}" \
        "/usr/local/lib/${suffix}" \
        "/opt/anaconda3/lib/${suffix}"
      do
        [[ -e "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
      done
      ;;
  esac

  return 1
}

bundle_dependency_tree() {
  local root_binary="$1"
  local ffmpeg_source="$2"

  local canonical_root
  canonical_root="$(canonicalize_path "${root_binary}")"
  if is_seen_dependency "${canonical_root}"; then
    return 0
  fi
  mark_seen_dependency "${canonical_root}"

  local dep
  local resolved_dep
  local dep_basename
  local target_dep_path
  while IFS= read -r dep; do
    [[ -n "${dep}" ]] || continue
    if is_system_library "${dep}"; then
      continue
    fi

    if ! resolved_dep="$(resolve_dependency_path "${dep}" "${root_binary}" "${ffmpeg_source}")"; then
      fail "Could not resolve ffmpeg dependency '${dep}' required by '${root_binary}'."
    fi

    dep_basename="$(basename "${dep}")"
    target_dep_path="${APP_LIB_DIR}/${dep_basename}"
    if [[ ! -e "${target_dep_path}" ]]; then
      cp -L "${resolved_dep}" "${target_dep_path}"
      chmod +x "${target_dep_path}" >/dev/null 2>&1 || true
    fi

    bundle_dependency_tree "${resolved_dep}" "${ffmpeg_source}"
  done < <(list_binary_deps "${root_binary}")
}

bundle_ffmpeg_runtime() {
  local ffmpeg_source="$1"

  cp -L "${ffmpeg_source}" "${APP_FFMPEG_PATH}"
  chmod +x "${APP_FFMPEG_PATH}"

  DEPENDENCY_SEEN_FILE="$(mktemp "${TMPDIR:-/tmp}/transcribe-ffdeps.XXXXXX")"
  TEMP_ITEMS+=("${DEPENDENCY_SEEN_FILE}")
  bundle_dependency_tree "${ffmpeg_source}" "${ffmpeg_source}"
}

create_icon_png() {
  local source_png="$1"
  local size="$2"
  local output_png="$3"
  sips -z "${size}" "${size}" "${source_png}" --out "${output_png}" >/dev/null
}

copy_or_build_icon() {
  local packaged_icon="${DIST_DIR}/AppIcon.icns"
  local source_logo="${PROJECT_ROOT}/logo_transcribe.png"
  local temp_dir
  local iconset_dir

  if [[ -f "${packaged_icon}" ]]; then
    cp "${packaged_icon}" "${APP_ICON_PATH}"
    return 0
  fi

  if [[ ! -f "${source_logo}" ]]; then
    fail "Icon source missing. Expected ${packaged_icon} or ${source_logo}."
  fi

  if ! command -v sips >/dev/null 2>&1 || ! command -v iconutil >/dev/null 2>&1; then
    fail "Cannot create AppIcon.icns without sips and iconutil. Install Xcode command line tools."
  fi

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/transcribe-icon.XXXXXX")"
  TEMP_ITEMS+=("${temp_dir}")
  iconset_dir="${temp_dir}/AppIcon.iconset"
  mkdir -p "${iconset_dir}"

  create_icon_png "${source_logo}" 16 "${iconset_dir}/icon_16x16.png"
  create_icon_png "${source_logo}" 32 "${iconset_dir}/icon_16x16@2x.png"
  create_icon_png "${source_logo}" 32 "${iconset_dir}/icon_32x32.png"
  create_icon_png "${source_logo}" 64 "${iconset_dir}/icon_32x32@2x.png"
  create_icon_png "${source_logo}" 128 "${iconset_dir}/icon_128x128.png"
  create_icon_png "${source_logo}" 256 "${iconset_dir}/icon_128x128@2x.png"
  create_icon_png "${source_logo}" 256 "${iconset_dir}/icon_256x256.png"
  create_icon_png "${source_logo}" 512 "${iconset_dir}/icon_256x256@2x.png"
  create_icon_png "${source_logo}" 512 "${iconset_dir}/icon_512x512.png"
  create_icon_png "${source_logo}" 1024 "${iconset_dir}/icon_512x512@2x.png"

  iconutil -c icns "${iconset_dir}" -o "${APP_ICON_PATH}"
}

write_info_plist() {
  cat > "${INFO_PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${PRODUCT_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_IDENTIFIER}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_MACOS_VERSION}</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF
}

write_pkg_postinstall_script() {
  local postinstall_path="$1"

  cat > "${postinstall_path}" <<'EOF'
#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/transcribe-installer.log"
APP_SUPPORT_ROOT="/Library/Application Support/Transcribe"
VENV_PATH="${APP_SUPPORT_ROOT}/venv"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

mkdir -p "$(dirname "${LOG_FILE}")"
exec >> "${LOG_FILE}" 2>&1

echo "[postinstall] $(date '+%Y-%m-%d %H:%M:%S') Starting Transcribe dependency install"

PYTHON_BIN="$(command -v python3 || true)"
if [[ -z "${PYTHON_BIN}" ]]; then
  echo "[postinstall] ERROR: python3 not found in PATH=${PATH}"
  exit 1
fi

echo "[postinstall] Using python3 at ${PYTHON_BIN}"
mkdir -p "${APP_SUPPORT_ROOT}"
"${PYTHON_BIN}" -m venv "${VENV_PATH}"
"${VENV_PATH}/bin/python3" -m pip install --upgrade pip
"${VENV_PATH}/bin/python3" -m pip install --upgrade openai-whisper

echo "[postinstall] Optional dependency whisperx is skipped by default due install size/runtime cost."
echo "[postinstall] $(date '+%Y-%m-%d %H:%M:%S') Dependency install complete"
exit 0
EOF

  chmod +x "${postinstall_path}"
}

build_installer_pkg() {
  local pkg_root_dir
  local pkg_scripts_dir
  local postinstall_script_path

  if ! command -v pkgbuild >/dev/null 2>&1; then
    fail "pkgbuild not found. Install Xcode command line tools to create ${PKG_PATH}."
  fi

  pkg_root_dir="$(mktemp -d "${TMPDIR:-/tmp}/transcribe-pkgroot.XXXXXX")"
  pkg_scripts_dir="$(mktemp -d "${TMPDIR:-/tmp}/transcribe-pkgscripts.XXXXXX")"
  TEMP_ITEMS+=("${pkg_root_dir}" "${pkg_scripts_dir}")

  mkdir -p "${pkg_root_dir}/Applications"
  cp -R "${APP_BUNDLE_PATH}" "${pkg_root_dir}/Applications/"

  postinstall_script_path="${pkg_scripts_dir}/postinstall"
  write_pkg_postinstall_script "${postinstall_script_path}"

  rm -f "${PKG_PATH}"
  pkgbuild \
    --root "${pkg_root_dir}" \
    --identifier "${PKG_IDENTIFIER}" \
    --version "${APP_VERSION}" \
    --install-location "/" \
    --scripts "${pkg_scripts_dir}" \
    "${PKG_PATH}" >/dev/null
}

sync_root_installer_artifacts() {
  [[ -f "${PKG_PATH}" ]] || fail "Expected package output is missing: ${PKG_PATH}"
  [[ -f "${DMG_PATH}" ]] || fail "Expected installer output is missing: ${DMG_PATH}"

  cp -f "${PKG_PATH}" "${ROOT_PKG_PATH}"
  cp -f "${DMG_PATH}" "${ROOT_DMG_PATH}"
}

main() {
  local ffmpeg_source
  local release_binary_path

  log "Building release binary"
  cd "${PROJECT_ROOT}"
  swift build -c release

  release_binary_path="${RELEASE_BINARY}"
  if [[ ! -x "${release_binary_path}" ]]; then
    release_binary_path="$(find "${PROJECT_ROOT}/.build" -type f -path "*/release/${PRODUCT_NAME}" -perm -111 | head -n 1 || true)"
  fi
  [[ -n "${release_binary_path}" && -x "${release_binary_path}" ]] || fail "Release binary not found for ${PRODUCT_NAME}."

  log "Staging app bundle at ${APP_BUNDLE_PATH}"
  rm -rf "${APP_BUNDLE_PATH}"
  mkdir -p "${APP_MACOS_DIR}" "${APP_RESOURCES_DIR}" "${APP_BIN_DIR}" "${APP_LIB_DIR}"

  cp "${release_binary_path}" "${APP_EXECUTABLE_PATH}"
  chmod +x "${APP_EXECUTABLE_PATH}"

  copy_or_build_icon
  write_info_plist

  ffmpeg_source="$(resolve_ffmpeg)"
  log "Bundling ffmpeg from ${ffmpeg_source}"
  bundle_ffmpeg_runtime "${ffmpeg_source}"

  log "Creating installer PKG at ${PKG_PATH}"
  build_installer_pkg

  log "Creating installer DMG at ${DMG_PATH}"
  rm -f "${DMG_PATH}"
  rm -rf "${DMG_STAGE_DIR}"
  mkdir -p "${DMG_STAGE_DIR}"
  cp -R "${APP_BUNDLE_PATH}" "${DMG_STAGE_DIR}/"
  cp "${PKG_PATH}" "${DMG_STAGE_DIR}/"
  ln -s /Applications "${DMG_STAGE_DIR}/Applications"

  hdiutil create \
    -volname "${APP_NAME} Installer" \
    -srcfolder "${DMG_STAGE_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" >/dev/null

  rm -rf "${DMG_STAGE_DIR}"
  sync_root_installer_artifacts

  log "Packaging complete"
  log "App bundle: ${APP_BUNDLE_PATH}"
  log "Package:    ${PKG_PATH}"
  log "Installer:  ${DMG_PATH}"
  log "Root pkg:   ${ROOT_PKG_PATH}"
  log "Root dmg:   ${ROOT_DMG_PATH}"
}

main "$@"
