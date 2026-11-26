#!/usr/bin/env bash
set -euo pipefail

# Build reproducible styled macOS arm64 DMG for LiteDictate (言落).
# All staging/intermediate artifacts live strictly under gitignored Build/.
#
# Usage:
#   Scripts/build-dmg.sh             # Reuses valid Build/LiteDictate.app if version matches, else builds
#   Scripts/build-dmg.sh --rebuild   # Forces fresh Scripts/build-app.sh build first
#   Scripts/build-dmg.sh --reuse-app # Reuses existing Build/LiteDictate.app without version/build rebuild

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${REPO_ROOT}/Build"
APP_BUNDLE="${BUILD_DIR}/LiteDictate.app"
PLIST_SRC="${REPO_ROOT}/Config/Info.plist"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${PLIST_SRC}")"
VOLUME_NAME="LiteDictate"
DMG_NAME="LiteDictate-${VERSION}-arm64.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
RW_DMG="${BUILD_DIR}/LiteDictate-${VERSION}-rw.dmg"
STAGING_DIR="${BUILD_DIR}/dmg-staging"
VERIFY_MNT="${BUILD_DIR}/dmg-verify-mnt"
SHA_FILE="${BUILD_DIR}/SHA256SUMS.txt"

JOBS="${JOBS:-2}"
FORCE_REBUILD=0
REUSE_APP=0

for arg in "$@"; do
  case "${arg}" in
    --rebuild)   FORCE_REBUILD=1 ;;
    --reuse-app) REUSE_APP=1 ;;
    *)
      echo "Usage: $0 [--rebuild | --reuse-app]" >&2
      exit 1
      ;;
  esac
done

ATTACHED_DEV=""
VERIFY_DEV=""

cleanup() {
  set +e
  if [[ -n "${ATTACHED_DEV}" ]]; then
    hdiutil detach "${ATTACHED_DEV}" -quiet 2>/dev/null || hdiutil detach -force "${ATTACHED_DEV}" -quiet 2>/dev/null || true
    ATTACHED_DEV=""
  fi
  if [[ -n "${VERIFY_DEV}" ]]; then
    hdiutil detach "${VERIFY_DEV}" -quiet 2>/dev/null || hdiutil detach -force "${VERIFY_DEV}" -quiet 2>/dev/null || true
    VERIFY_DEV=""
  fi
  rm -f "${RW_DMG}"
  rm -rf "${STAGING_DIR}" "${VERIFY_MNT}"
}
trap cleanup EXIT

# Step 1: Ensure signed Build/LiteDictate.app is ready
NEED_BUILD=0
if [[ "${FORCE_REBUILD}" -eq 1 ]]; then
  NEED_BUILD=1
elif [[ ! -d "${APP_BUNDLE}" ]]; then
  NEED_BUILD=1
elif [[ "${REUSE_APP}" -eq 0 ]]; then
  APP_VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "${APP_VER}" != "${VERSION}" ]]; then
    echo "[build-dmg] Existing Build/LiteDictate.app version (${APP_VER:-unknown}) != Info.plist (${VERSION}); rebuilding..."
    NEED_BUILD=1
  elif [[ ! -s "${APP_BUNDLE}/Contents/Resources/Notices/LICENSE" || ! -s "${APP_BUNDLE}/Contents/Resources/Notices/THIRD_PARTY_NOTICES.md" ]]; then
    echo "[build-dmg] Existing Build/LiteDictate.app missing bundled Notices/; rebuilding..."
    NEED_BUILD=1
  elif ! codesign --verify --strict "${APP_BUNDLE}" >/dev/null 2>&1; then
    echo "[build-dmg] Existing Build/LiteDictate.app failed signature check; rebuilding..."
    NEED_BUILD=1
  fi
fi

if [[ "${NEED_BUILD}" -eq 1 ]]; then
  echo "[build-dmg] Building fresh Release LiteDictate.app (JOBS=${JOBS})..."
  JOBS="${JOBS}" bash "${SCRIPT_DIR}/build-app.sh"
else
  echo "[build-dmg] Reusing verified signed ${APP_BUNDLE}"
  codesign --verify --strict "${APP_BUNDLE}"
fi

if [[ ! -s "${APP_BUNDLE}/Contents/Resources/Notices/LICENSE" || ! -s "${APP_BUNDLE}/Contents/Resources/Notices/THIRD_PARTY_NOTICES.md" ]]; then
  echo "[build-dmg] ERROR: Bundled MIT LICENSE / THIRD_PARTY_NOTICES.md missing under Contents/Resources/Notices/" >&2
  exit 1
fi

# Step 2: Prepare clean staging directory inside Build/dmg-staging/
echo "[build-dmg] Preparing staging directory ${STAGING_DIR}..."
rm -rf "${STAGING_DIR}" "${RW_DMG}" "${DMG_PATH}" "${VERIFY_MNT}"
mkdir -p "${STAGING_DIR}/.background"

ditto "${APP_BUNDLE}" "${STAGING_DIR}/LiteDictate.app"
ln -s /Applications "${STAGING_DIR}/Applications"

ICON_SRC="${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
if [[ ! -f "${ICON_SRC}" && -f "${BUILD_DIR}/AppIcon.icns" ]]; then
  ICON_SRC="${BUILD_DIR}/AppIcon.icns"
fi
if [[ -f "${ICON_SRC}" ]]; then
  cp -f "${ICON_SRC}" "${STAGING_DIR}/.VolumeIcon.icns"
fi

# Generate subtle obsidian-indigo Finder background (600x380) using CoreGraphics
BG_PNG="${STAGING_DIR}/.background/dmg-bg.png"
swift - "${BG_PNG}" "${VERSION}" << 'SWIFT_BG' || true
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { exit(0) }
let outPath = args[1]
let version = args[2]

let width = 600
let height = 380
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(0) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Deep obsidian-indigo background matching AppIcon.svg
let cs = CGColorSpaceCreateDeviceRGB()
let bgColors = [
    CGColor(colorSpace: cs, components: [0.06, 0.09, 0.16, 1.0])!,
    CGColor(colorSpace: cs, components: [0.04, 0.05, 0.10, 1.0])!,
] as CFArray
if let grad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0.0, 1.0]) {
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
}

// Subtle top ambient cyan aura
let auraColors = [
    CGColor(colorSpace: cs, components: [0.22, 0.74, 0.97, 0.16])!,
    CGColor(colorSpace: cs, components: [0.22, 0.74, 0.97, 0.0])!,
] as CFArray
if let aura = CGGradient(colorsSpace: cs, colors: auraColors, locations: [0.0, 1.0]) {
    ctx.drawRadialGradient(
        aura,
        startCenter: CGPoint(x: 300, y: 310),
        startRadius: 10,
        endCenter: CGPoint(x: 300, y: 310),
        endRadius: 280,
        options: []
    )
}

// Subtle arrow in center pointing from LiteDictate.app (left) to Applications (right)
ctx.setStrokeColor(CGColor(colorSpace: cs, components: [0.49, 0.83, 0.99, 0.72])!)
ctx.setLineWidth(3.0)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let arrowY: CGFloat = 190
ctx.move(to: CGPoint(x: 268, y: arrowY))
ctx.addLine(to: CGPoint(x: 332, y: arrowY))
ctx.move(to: CGPoint(x: 318, y: arrowY + 12))
ctx.addLine(to: CGPoint(x: 332, y: arrowY))
ctx.addLine(to: CGPoint(x: 318, y: arrowY - 12))
ctx.strokePath()

// Subtle title & drag hint
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.90, green: 0.96, blue: 1.0, alpha: 0.92),
]
let title = "LiteDictate (言落) \(version)" as NSString
let tSize = title.size(withAttributes: titleAttrs)
title.draw(at: NSPoint(x: (CGFloat(width) - tSize.width) / 2.0, y: 326), withAttributes: titleAttrs)

let hintAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
    .foregroundColor: NSColor(calibratedRed: 0.65, green: 0.78, blue: 0.90, alpha: 0.78),
]
let hint = "Drag LiteDictate to Applications to install" as NSString
let hSize = hint.size(withAttributes: hintAttrs)
hint.draw(at: NSPoint(x: (CGFloat(width) - hSize.width) / 2.0, y: 36), withAttributes: hintAttrs)

NSGraphicsContext.restoreGraphicsState()

if let data = rep.representation(using: .png, properties: [:]) {
    try? data.write(to: URL(fileURLWithPath: outPath))
}
SWIFT_BG

# Step 3: Create read-write UDRW DMG
STAGING_MB="$(du -sm "${STAGING_DIR}" | awk '{print $1}')"
IMAGE_MB="$((STAGING_MB + 32))"
echo "[build-dmg] Creating temporary UDRW image (${IMAGE_MB} MB)..."
hdiutil create \
  -srcfolder "${STAGING_DIR}" \
  -volname "${VOLUME_NAME}" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  -size "${IMAGE_MB}m" \
  "${RW_DMG}" >/dev/null

# Step 4: Mount UDRW image, apply custom volume icon & Finder window layout (graceful fallback if headless)
ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "${RW_DMG}")"
ATTACHED_DEV="$(printf '%s\n' "${ATTACH_OUT}" | awk '/^\/dev\// {print $1; exit}')"
MOUNT_DIR="$(printf '%s\n' "${ATTACH_OUT}" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"

if [[ -z "${ATTACHED_DEV}" || -z "${MOUNT_DIR}" || ! -d "${MOUNT_DIR}" ]]; then
  echo "[build-dmg] ERROR: Failed to attach temporary UDRW DMG" >&2
  exit 1
fi
echo "[build-dmg] Mounted ${ATTACHED_DEV} at ${MOUNT_DIR}"

if [[ -f "${MOUNT_DIR}/.VolumeIcon.icns" ]]; then
  SETFILE_BIN="$(command -v SetFile || xcrun -f SetFile 2>/dev/null || true)"
  if [[ -n "${SETFILE_BIN}" ]]; then
    "${SETFILE_BIN}" -a C "${MOUNT_DIR}" || true
    "${SETFILE_BIN}" -a V "${MOUNT_DIR}/.VolumeIcon.icns" || true
    echo "[build-dmg] Applied custom volume icon (.VolumeIcon.icns)"
  fi
fi

# Best-effort Finder layout via AppleScript (never fails build in headless/non-interactive shells)
MOUNT_BASENAME="$(basename "${MOUNT_DIR}")"
if pgrep -x Finder >/dev/null 2>&1; then
  echo "[build-dmg] Applying Finder window layout (best-effort)..."
  osascript - "${MOUNT_BASENAME}" << 'APPLESCRIPT' >/dev/null 2>&1 || echo "[build-dmg] Note: Finder AppleScript styling skipped (headless or automation not permitted)"
on run argv
  set volName to item 1 of argv
  with timeout of 15 seconds
    tell application "Finder"
      tell disk volName
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, 800, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 108
        try
          set background picture of viewOptions to file ".background:dmg-bg.png"
        end try
        set position of item "LiteDictate.app" of container window to {165, 190}
        set position of item "Applications" of container window to {435, 190}
        update without registering applications
        delay 1
        close
      end tell
    end tell
  end timeout
end run
APPLESCRIPT
fi

sync
sleep 1
hdiutil detach "${ATTACHED_DEV}" -quiet || hdiutil detach -force "${ATTACHED_DEV}" -quiet
ATTACHED_DEV=""

# Step 5: Convert to final compressed UDZO DMG
echo "[build-dmg] Compressing final UDZO image -> ${DMG_PATH}..."
hdiutil convert "${RW_DMG}" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "${DMG_PATH}" >/dev/null
rm -f "${RW_DMG}"

# Step 6: Verify DMG integrity and mounted app codesign
echo "[build-dmg] Verifying DMG checksum and structure..."
hdiutil verify "${DMG_PATH}"

mkdir -p "${VERIFY_MNT}"
VERIFY_OUT="$(hdiutil attach -nobrowse -readonly -noverify -mountpoint "${VERIFY_MNT}" "${DMG_PATH}")"
VERIFY_DEV="$(printf '%s\n' "${VERIFY_OUT}" | awk '/^\/dev\// {print $1; exit}')"

if [[ ! -L "${VERIFY_MNT}/Applications" || "$(readlink "${VERIFY_MNT}/Applications")" != "/Applications" ]]; then
  echo "[build-dmg] ERROR: Applications symlink missing or invalid inside DMG" >&2
  exit 1
fi

if [[ ! -s "${VERIFY_MNT}/LiteDictate.app/Contents/Resources/Notices/LICENSE" || ! -s "${VERIFY_MNT}/LiteDictate.app/Contents/Resources/Notices/THIRD_PARTY_NOTICES.md" ]]; then
  echo "[build-dmg] ERROR: LICENSE / THIRD_PARTY_NOTICES.md missing inside mounted LiteDictate.app/Contents/Resources/Notices/" >&2
  exit 1
fi

echo "[build-dmg] Verifying strict codesign of LiteDictate.app inside mounted DMG..."
for dylib in "${VERIFY_MNT}/LiteDictate.app/Contents/Frameworks/"*.dylib; do
  codesign --verify --strict --verbose=1 "${dylib}"
done
codesign --verify --strict --verbose=1 "${VERIFY_MNT}/LiteDictate.app/Contents/MacOS/litedictate-worker"
codesign --verify --strict --verbose=2 "${VERIFY_MNT}/LiteDictate.app"

hdiutil detach "${VERIFY_DEV}" -quiet || hdiutil detach -force "${VERIFY_DEV}" -quiet
VERIFY_DEV=""
rm -rf "${VERIFY_MNT}" "${STAGING_DIR}"

# Step 7: Write Build/SHA256SUMS.txt
(cd "${BUILD_DIR}" && shasum -a 256 "${DMG_NAME}" > "${SHA_FILE}")

DMG_SIZE="$(du -h "${DMG_PATH}" | awk '{print $1}')"
echo "[build-dmg] SUCCESS: ${DMG_PATH} (${DMG_SIZE})"
echo "[build-dmg] SHA256SUMS.txt:"
cat "${SHA_FILE}"
