#!/usr/bin/env bash
set -euo pipefail

# Build & sign LiteDictate (言落) Release macOS .app bundle.
# Strict 8 GB RAM discipline: JOBS defaults to 2 and is safely clamped to 1..4.
# Strict Apple signing order (Section 9.3):
#   1. Frameworks/*.dylib
#   2. MacOS/litedictate-worker
#   3. LiteDictate.app (Hardened Runtime + Library Validation when using a signing identity)
#
# Signing options:
#   SIGN_IDENTITY="Developer ID Application: ..."  -> Use explicit identity + Hardened Runtime
#   SIGN_IDENTITY="-" or SIGN_MODE=adhoc           -> Ad-hoc local signing (for open-source builds)
#   (unset)                                        -> Auto-select Developer ID / Apple Development if available, else ad-hoc

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${REPO_ROOT}/Build"
ENGINE_DIR="${BUILD_DIR}/Engine"
FRAMEWORKS_DEV_DIR="${BUILD_DIR}/Frameworks"
CMAKE_BUILD_DIR="${BUILD_DIR}/cmake-release"
WORKER_BIN="${BUILD_DIR}/Worker/litedictate-worker"
APP_BUNDLE="${BUILD_DIR}/LiteDictate.app"

WORKER_ONLY=0
for arg in "$@"; do
  case "${arg}" in
    --worker-only) WORKER_ONLY=1 ;;
    *)
      echo "Usage: $0 [--worker-only]" >&2
      exit 1
      ;;
  esac
done

# Clamp JOBS safely to 1..4 (default 2 for 8 GB Apple Silicon Macs)
RAW_JOBS="${JOBS:-2}"
if ! [[ "${RAW_JOBS}" =~ ^[0-9]+$ ]]; then
  echo "[build-app] WARNING: Invalid JOBS='${RAW_JOBS}', falling back to 2" >&2
  JOBS=2
elif (( RAW_JOBS < 1 )); then
  echo "[build-app] WARNING: JOBS=${RAW_JOBS} < 1, clamping to 1" >&2
  JOBS=1
elif (( RAW_JOBS > 4 )); then
  echo "[build-app] WARNING: JOBS=${RAW_JOBS} > 4, clamping to 4 for 8 GB RAM safety" >&2
  JOBS=4
else
  JOBS="${RAW_JOBS}"
fi

# Resolve cmake portably (PATH -> Homebrew Apple Silicon -> Homebrew Intel)
CMAKE_BIN="${CMAKE_BIN:-$(command -v cmake || true)}"
if [[ -z "${CMAKE_BIN}" ]]; then
  for candidate in /opt/homebrew/bin/cmake /usr/local/bin/cmake; do
    if [[ -x "${candidate}" ]]; then
      CMAKE_BIN="${candidate}"
      break
    fi
  done
fi
if [[ -z "${CMAKE_BIN}" || ! -x "${CMAKE_BIN}" ]]; then
  echo "[build-app] ERROR: cmake not found in PATH, /opt/homebrew/bin, or /usr/local/bin. Install via: brew install cmake ninja" >&2
  exit 1
fi

NINJA_BIN="$(command -v ninja || true)"
if [[ -z "${NINJA_BIN}" ]]; then
  for candidate in /opt/homebrew/bin/ninja /usr/local/bin/ninja; do
    if [[ -x "${candidate}" ]]; then
      NINJA_BIN="${candidate}"
      break
    fi
  done
fi
CMAKE_GEN_ARGS=()
if [[ -n "${NINJA_BIN}" && -x "${NINJA_BIN}" ]]; then
  CMAKE_GEN_ARGS=(-G Ninja "-DCMAKE_MAKE_PROGRAM=${NINJA_BIN}")
fi

# Resolve signing identity portably (no personal identity hardcoded)
SIGN_MODE="${SIGN_MODE:-auto}"
RESOLVED_IDENTITY=""
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  RESOLVED_IDENTITY="${SIGN_IDENTITY}"
elif [[ "${SIGN_MODE}" == "adhoc" ]]; then
  RESOLVED_IDENTITY="-"
else
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  RESOLVED_IDENTITY="$(printf '%s\n' "${IDENTITIES}" | sed -n 's/^[[:space:]]*[0-9][0-9]*)[[:space:]]*[0-9A-Fa-f]*[[:space:]]*"\(Developer ID Application:[^"]*\)"/\1/p' | head -n 1)"
  if [[ -z "${RESOLVED_IDENTITY}" ]]; then
    RESOLVED_IDENTITY="$(printf '%s\n' "${IDENTITIES}" | sed -n 's/^[[:space:]]*[0-9][0-9]*)[[:space:]]*[0-9A-Fa-f]*[[:space:]]*"\(Apple Development:[^"]*\)"/\1/p' | head -n 1)"
  fi
  if [[ -z "${RESOLVED_IDENTITY}" ]]; then
    RESOLVED_IDENTITY="-"
  fi
fi

if [[ "${RESOLVED_IDENTITY}" == "-" ]]; then
  echo "[build-app] Signing mode: ad-hoc ('-'). Pass SIGN_IDENTITY=\"Apple Development: ...\" or \"Developer ID Application: ...\" for Hardened Runtime + persistent TCC."
else
  echo "[build-app] Signing identity: ${RESOLVED_IDENTITY} (Hardened Runtime + Library Validation)"
fi

sign_item() {
  local target="$1"
  local entitlements="${2:-}"
  if [[ "${RESOLVED_IDENTITY}" == "-" ]]; then
    if [[ -n "${entitlements}" ]]; then
      codesign --force --entitlements "${entitlements}" --sign - "${target}"
    else
      codesign --force --sign - "${target}"
    fi
  else
    if [[ -n "${entitlements}" ]]; then
      codesign --force --options runtime --entitlements "${entitlements}" --sign "${RESOLVED_IDENTITY}" "${target}"
    else
      codesign --force --options runtime --sign "${RESOLVED_IDENTITY}" "${target}"
    fi
  fi
}

echo "[build-app] Step 1: Ensuring SHA-256-verified transcribe.cpp v0.4.1 engine dylibs..."
bash "${SCRIPT_DIR}/fetch-transcribe-cpp.sh"

echo "[build-app] Step 2: Building C++17 litedictate-worker (Release, -j ${JOBS}, cmake=${CMAKE_BIN})..."
"${CMAKE_BIN}" -S "${REPO_ROOT}" -B "${CMAKE_BUILD_DIR}" \
  "${CMAKE_GEN_ARGS[@]}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DLITEDICTATE_ENGINE_DIR="${ENGINE_DIR}"
"${CMAKE_BIN}" --build "${CMAKE_BUILD_DIR}" -j "${JOBS}"

if [[ ! -x "${WORKER_BIN}" ]]; then
  echo "[build-app] ERROR: Missing worker binary at ${WORKER_BIN}" >&2
  exit 1
fi

if [[ "${WORKER_ONLY}" -eq 1 ]]; then
  # Copy untouched Build/Engine/*.dylib into Build/Frameworks/ before signing so
  # Build/Engine/ always retains exact upstream SHA-256 hashes.
  echo "[build-app] Staging and signing Build/Frameworks/*.dylib and Build/Worker/litedictate-worker..."
  mkdir -p "${FRAMEWORKS_DEV_DIR}"
  for dylib in "${ENGINE_DIR}/"*.dylib; do
    dst="${FRAMEWORKS_DEV_DIR}/$(basename "${dylib}")"
    cp -f "${dylib}" "${dst}"
    chmod 755 "${dst}"
    sign_item "${dst}"
  done
  sign_item "${WORKER_BIN}"
  for dylib in "${FRAMEWORKS_DEV_DIR}/"*.dylib; do
    codesign --verify --strict --verbose=1 "${dylib}"
  done
  codesign --verify --strict --verbose=1 "${WORKER_BIN}"
  echo "[build-app] Worker-only build and signature verification complete."
  exit 0
fi

echo "[build-app] Step 3: Building SwiftPM Release LiteDictateApp (-j ${JOBS})..."
cd "${REPO_ROOT}"
swift build -c release -j "${JOBS}" --product LiteDictateApp
SWIFT_BIN_DIR="$(swift build -c release --show-bin-path)"
SWIFT_APP_BIN="${SWIFT_BIN_DIR}/LiteDictateApp"

if [[ ! -x "${SWIFT_APP_BIN}" ]]; then
  echo "[build-app] ERROR: Missing Swift executable at ${SWIFT_APP_BIN}" >&2
  exit 1
fi

echo "[build-app] Step 4: Generating AppIcon.icns, bundling Notices, and assembling ${APP_BUNDLE}..."
bash "${SCRIPT_DIR}/generate-icon.sh"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
mkdir -p "${APP_BUNDLE}/Contents/Resources/Notices"

cp -f "${REPO_ROOT}/Config/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp -f "${BUILD_DIR}/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
cp -f "${REPO_ROOT}/LICENSE" "${APP_BUNDLE}/Contents/Resources/Notices/LICENSE"
cp -f "${REPO_ROOT}/THIRD_PARTY_NOTICES.md" "${APP_BUNDLE}/Contents/Resources/Notices/THIRD_PARTY_NOTICES.md"
if [[ -d "${ENGINE_DIR}/licenses" ]]; then
  mkdir -p "${APP_BUNDLE}/Contents/Resources/Notices/transcribe-cpp"
  cp -f "${ENGINE_DIR}/licenses/"* "${APP_BUNDLE}/Contents/Resources/Notices/transcribe-cpp/" 2>/dev/null || true
fi

cp -f "${SWIFT_APP_BIN}" "${APP_BUNDLE}/Contents/MacOS/LiteDictateApp"
cp -f "${WORKER_BIN}" "${APP_BUNDLE}/Contents/MacOS/litedictate-worker"
chmod 755 "${APP_BUNDLE}/Contents/MacOS/LiteDictateApp" "${APP_BUNDLE}/Contents/MacOS/litedictate-worker"

for dylib in "${ENGINE_DIR}/"*.dylib; do
  cp -f "${dylib}" "${APP_BUNDLE}/Contents/Frameworks/"
  chmod 755 "${APP_BUNDLE}/Contents/Frameworks/$(basename "${dylib}")"
done

# Ensure LiteDictate.app does not inherit quarantine or resource fork clutter
xattr -cr "${APP_BUNDLE}" 2>/dev/null || true

echo "[build-app] Step 5: Signing in strict order (Frameworks/*.dylib -> MacOS/litedictate-worker -> LiteDictate.app)..."
# 5a. Sign Frameworks/*.dylib first
for dylib in "${APP_BUNDLE}/Contents/Frameworks/"*.dylib; do
  echo "  [sign] $(basename "${dylib}")"
  sign_item "${dylib}"
done

# 5b. Sign nested helper binary MacOS/litedictate-worker second
echo "  [sign] MacOS/litedictate-worker"
sign_item "${APP_BUNDLE}/Contents/MacOS/litedictate-worker"

# 5c. Sign main LiteDictate.app bundle last
echo "  [sign] LiteDictate.app"
sign_item "${APP_BUNDLE}" "${REPO_ROOT}/Config/LiteDictate.entitlements"

echo "[build-app] Step 6: Verifying signatures (--strict)..."
for dylib in "${APP_BUNDLE}/Contents/Frameworks/"*.dylib; do
  codesign --verify --strict --verbose=1 "${dylib}"
done
codesign --verify --strict --verbose=1 "${APP_BUNDLE}/Contents/MacOS/litedictate-worker"
codesign --verify --strict --verbose=2 "${APP_BUNDLE}"

echo "[build-app] SUCCESS: Built and signed ${APP_BUNDLE}"
