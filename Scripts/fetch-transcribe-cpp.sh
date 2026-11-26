#!/usr/bin/env bash
set -euo pipefail

# Fetch and SHA-256-verify MIT-licensed handy-computer/transcribe.cpp v0.4.1
# darwin-arm64-metal native libraries into Build/Engine/ (never committed to git).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENGINE_DIR="${REPO_ROOT}/Build/Engine"
CHECKSUM_FILE="${SCRIPT_DIR}/transcribe-v0.4.1.sha256"
VERSION="0.4.1"
EXPECTED_HEADER_HASH="f99ad4169374b8f3"
NPM_PACKAGE_URL="https://registry.npmjs.org/@transcribe-cpp/darwin-arm64-metal/-/darwin-arm64-metal-${VERSION}.tgz"

REQUIRED_DYLIBS=(
  "libtranscribe.dylib"
  "libggml.dylib"
  "libggml-base.dylib"
  "libggml-cpu.dylib"
  "libggml-metal.dylib"
)

if [[ ! -f "${CHECKSUM_FILE}" ]]; then
  echo "[fetch-transcribe-cpp] ERROR: Missing pinned SHA-256 manifest at ${CHECKSUM_FILE}" >&2
  exit 1
fi

verify_dir() {
  local dir="$1"
  local verbose="${2:-0}"

  for lib in "${REQUIRED_DYLIBS[@]}"; do
    [[ -f "${dir}/${lib}" ]] || return 1
  done

  # Fail closed: contract.json must exist and match exact version + ABI header hash
  if [[ ! -f "${dir}/contract.json" ]]; then
    return 1
  fi
  grep -q "\"version\"[[:space:]]*:[[:space:]]*\"${VERSION}\"" "${dir}/contract.json" || return 1
  grep -q "\"header_hash\"[[:space:]]*:[[:space:]]*\"${EXPECTED_HEADER_HASH}\"" "${dir}/contract.json" || return 1

  # Fail closed: every dylib must match pinned SHA-256 checksum
  if [[ "${verbose}" -eq 1 ]]; then
    (cd "${dir}" && shasum -a 256 -c "${CHECKSUM_FILE}")
  else
    (cd "${dir}" && shasum -a 256 -c "${CHECKSUM_FILE}" >/dev/null 2>&1)
  fi
}

copy_from_dir() {
  local src="$1"
  mkdir -p "${ENGINE_DIR}"
  for lib in "${REQUIRED_DYLIBS[@]}"; do
    cp -f "${src}/${lib}" "${ENGINE_DIR}/${lib}"
    chmod 755 "${ENGINE_DIR}/${lib}"
  done
  cp -f "${src}/contract.json" "${ENGINE_DIR}/contract.json"
  if [[ -d "${src}/licenses" ]]; then
    mkdir -p "${ENGINE_DIR}/licenses"
    cp -f "${src}/licenses/"* "${ENGINE_DIR}/licenses/" 2>/dev/null || true
  fi
}

# 1. Reuse already-staged Build/Engine if it passes full contract + SHA-256 verification
if verify_dir "${ENGINE_DIR}"; then
  echo "[fetch-transcribe-cpp] Verified existing v${VERSION} dylibs in ${ENGINE_DIR} (SHA-256 OK)"
  exit 0
fi

# 2. Optional local override directory (must still pass full contract + SHA-256 verification)
if [[ -n "${TRANSCRIBE_CPP_DIR:-}" ]]; then
  if verify_dir "${TRANSCRIBE_CPP_DIR}"; then
    echo "[fetch-transcribe-cpp] Copying SHA-256-verified v${VERSION} dylibs from TRANSCRIBE_CPP_DIR=${TRANSCRIBE_CPP_DIR}"
    copy_from_dir "${TRANSCRIBE_CPP_DIR}"
    verify_dir "${ENGINE_DIR}" 1
    exit 0
  else
    echo "[fetch-transcribe-cpp] ERROR: TRANSCRIBE_CPP_DIR=${TRANSCRIBE_CPP_DIR} failed v${VERSION} contract/SHA-256 verification" >&2
    exit 1
  fi
fi

# 3. Download official MIT prebuilt package from npmjs.org and enforce pinned SHA-256 verification
echo "[fetch-transcribe-cpp] Downloading @transcribe-cpp/darwin-arm64-metal@${VERSION}..."
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/transcribe-cpp-fetch.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

TARBALL="${TMP_DIR}/darwin-arm64-metal-${VERSION}.tgz"
curl -fsSL --retry 3 "${NPM_PACKAGE_URL}" -o "${TARBALL}"
tar -xzf "${TARBALL}" -C "${TMP_DIR}"

if ! verify_dir "${TMP_DIR}/package" 1; then
  echo "[fetch-transcribe-cpp] ERROR: Downloaded package failed v${VERSION} contract or SHA-256 verification!" >&2
  exit 1
fi

copy_from_dir "${TMP_DIR}/package"
verify_dir "${ENGINE_DIR}" 0
echo "[fetch-transcribe-cpp] Installed SHA-256-verified v${VERSION} dylibs into ${ENGINE_DIR}"
