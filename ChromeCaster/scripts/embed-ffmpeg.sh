#!/bin/sh
# Embeds ffmpeg + copies linked dylibs into the app so App Sandbox can load them.
#
# Every install_name_tool -change invalidates the code signature. We must re-sign
# all embedded dylibs + ffmpeg after rewriting load paths, or AMFI often SIGKILLs
# the child (Process reports signal 9).
#
# Prefer the same identity Xcode uses for the app (EXPANDED_CODE_SIGN_IDENTITY).

set -eu

APP="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
MACOS_DIR="${EXECUTABLE_FOLDER_PATH}"
if [ -z "${MACOS_DIR}" ] || [ ! -d "${MACOS_DIR}" ]; then
  MACOS_DIR="${APP}/Contents/MacOS"
fi
DEST="${MACOS_DIR}/ffmpeg"
FWK="${APP}/Contents/Frameworks"

REL_MACOS='@loader_path/../Frameworks'
REL_FW='@loader_path'

SRC=""
if [ -n "${FFMPEG_EMBED_PATH:-}" ] && [ -x "${FFMPEG_EMBED_PATH}" ]; then
  SRC="${FFMPEG_EMBED_PATH}"
elif [ -x /opt/homebrew/bin/ffmpeg ]; then
  SRC=/opt/homebrew/bin/ffmpeg
elif [ -x /usr/local/bin/ffmpeg ]; then
  SRC=/usr/local/bin/ffmpeg
elif [ -x /opt/local/bin/ffmpeg ]; then
  SRC=/opt/local/bin/ffmpeg
elif command -v ffmpeg >/dev/null 2>&1; then
  SRC=$(command -v ffmpeg)
fi

if [ -z "${SRC}" ]; then
  echo "warning: ffmpeg not found. Install: brew install ffmpeg, then clean build." >&2
  exit 0
fi

mkdir -p "${MACOS_DIR}" "${FWK}"
echo "note: Embed ffmpeg: ${SRC} -> ${DEST}"
cp -f "${SRC}" "${DEST}"
chmod +x "${DEST}"

OTMP="${TMPDIR:-/tmp}/chromecaster-otool-$$.txt"
round=0
while [ "${round}" -lt 50 ]; do
  round=$((round + 1))
  added=0

  for bin in "${DEST}" $(find "${FWK}" -maxdepth 1 -name '*.dylib' 2>/dev/null); do
    [ -f "${bin}" ] || continue

    if [ "${bin}" = "${DEST}" ]; then
      REL="${REL_MACOS}"
    else
      REL="${REL_FW}"
    fi

    otool -L "${bin}" | tail -n +2 | sed 's/^[[:space:]]*//' >"${OTMP}"
    while IFS= read -r line; do
      dep=$(echo "${line}" | awk '{print $1}')
      case "${dep}" in
        @*) continue ;;
      esac
      case "${dep}" in
        /usr/lib/*|/System/*|/usr/lib/system/*) continue ;;
      esac
      [ -f "${dep}" ] || continue

      base=$(basename "${dep}")
      if [ ! -f "${FWK}/${base}" ]; then
        echo "note: bundling ${base}"
        cp -f "${dep}" "${FWK}/${base}"
        chmod +x "${FWK}/${base}"
        added=1
      fi
      install_name_tool -change "${dep}" "${REL}/${base}" "${bin}" 2>/dev/null || true
    done <"${OTMP}"
  done

  rm -f "${OTMP}"
  if [ "${added}" -eq 0 ]; then
    break
  fi
done

# Re-sign after all install_name_tool mutations (signatures were invalidated).
SIGN="-"
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
  SIGN="${EXPANDED_CODE_SIGN_IDENTITY}"
elif [ -n "${CODE_SIGN_IDENTITY:-}" ] && [ "${CODE_SIGN_IDENTITY}" != "-" ] && [ "${CODE_SIGN_IDENTITY}" != "" ]; then
  SIGN="${CODE_SIGN_IDENTITY}"
fi

echo "note: Re-signing embedded FFmpeg + dylibs (identity: ${SIGN})"

csign() {
  _path="$1"
  if ! codesign --force --sign "${SIGN}" "${_path}"; then
    echo "warning: codesign with app identity failed for ${_path}; trying adhoc" >&2
    codesign --force --sign - "${_path}" || true
  fi
}

# Dylibs first, then the ffmpeg executable.
if [ -d "${FWK}" ]; then
  for lib in "${FWK}"/*.dylib; do
    [ -f "${lib}" ] || continue
    csign "${lib}"
  done
fi
csign "${DEST}"

echo "note: ffmpeg embed + dylib bundle complete."
