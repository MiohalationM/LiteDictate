#!/usr/bin/env bash
set -euo pipefail

# Rasterize Resources/AppIcon.svg into a complete macOS AppIcon.iconset
# and compile Build/AppIcon.icns (all intermediates stay inside gitignored Build/).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SVG_SRC="${REPO_ROOT}/Resources/AppIcon.svg"
BUILD_DIR="${REPO_ROOT}/Build"
ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"
ICON_1024_PNG="${BUILD_DIR}/AppIcon-1024.png"
ICNS_OUT="${BUILD_DIR}/AppIcon.icns"

if [[ ! -f "${SVG_SRC}" ]]; then
  echo "[generate-icon] ERROR: Missing source SVG at ${SVG_SRC}" >&2
  exit 1
fi

mkdir -p "${BUILD_DIR}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/litedictate-icon.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

RAW_PNG="${TMP_DIR}/raw.png"
RENDER_SWIFT="${TMP_DIR}/render_svg.swift"

cat << 'SWIFT_EOF' > "${RENDER_SWIFT}"
import AppKit
import Foundation
import WebKit

final class SVGRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let outPath: String

    init(svgPath: String, outPath: String) {
        self.outPath = outPath
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024), configuration: config)
        super.init()
        self.webView.navigationDelegate = self
        self.webView.setValue(false, forKey: "drawsBackground")

        guard let svg = try? String(contentsOfFile: svgPath, encoding: .utf8) else {
            fputs("[generate-icon] Failed to read SVG at \(svgPath)\n", stderr)
            exit(1)
        }
        let html = """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          html, body {
            margin: 0;
            padding: 0;
            width: 1024px;
            height: 1024px;
            background: transparent;
            overflow: hidden;
          }
          svg {
            display: block;
            width: 1024px;
            height: 1024px;
          }
        </style>
        </head>
        <body>\(svg)</body>
        </html>
        """
        self.webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fputs("[generate-icon] WebKit navigation failed: \(error)\n", stderr)
        exit(1)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let snap = WKSnapshotConfiguration()
            snap.rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
            snap.snapshotWidth = 1024
            webView.takeSnapshot(with: snap) { image, error in
                guard let image = image, error == nil else {
                    fputs("[generate-icon] WebKit snapshot failed: \(String(describing: error))\n", stderr)
                    exit(1)
                }
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    fputs("[generate-icon] Failed to extract CGImage from snapshot\n", stderr)
                    exit(1)
                }
                let rep = NSBitmapImageRep(cgImage: cgImage)
                // Sanity-check: corners must be transparent and center must be visible/non-blank
                let w = rep.pixelsWide
                let h = rep.pixelsHigh
                guard w >= 1024, h >= 1024 else {
                    fputs("[generate-icon] Unexpected snapshot dimensions: \(w)x\(h)\n", stderr)
                    exit(1)
                }
                let corner = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB)
                let center = rep.colorAt(x: w / 2, y: h / 2)?.usingColorSpace(.sRGB)
                if let c = corner, c.alphaComponent > 0.05 {
                    fputs("[generate-icon] WARNING: Expected transparent corner, alpha=\(c.alphaComponent)\n", stderr)
                }
                guard let mid = center, mid.alphaComponent > 0.9,
                      (mid.redComponent + mid.greenComponent + mid.blueComponent) > 0.3 else {
                    fputs("[generate-icon] ERROR: Center pixel appears blank/broken: \(String(describing: center))\n", stderr)
                    exit(1)
                }
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    fputs("[generate-icon] Failed to encode PNG\n", stderr)
                    exit(1)
                }
                do {
                    try png.write(to: URL(fileURLWithPath: self.outPath))
                    exit(0)
                } catch {
                    fputs("[generate-icon] Failed to write PNG: \(error)\n", stderr)
                    exit(1)
                }
            }
        }
    }
}

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("Usage: render_svg.swift <input.svg> <output.png>\n", stderr)
    exit(1)
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = SVGRenderer(svgPath: args[1], outPath: args[2])
withExtendedLifetime(renderer) {
    app.run()
}
SWIFT_EOF

echo "[generate-icon] Rasterizing ${SVG_SRC} via WebKit full-SVG engine..."
if ! swift "${RENDER_SWIFT}" "${SVG_SRC}" "${RAW_PNG}"; then
  echo "[generate-icon] WebKit render unavailable, falling back to qlmanage..." >&2
  qlmanage -t -s 1024 -o "${TMP_DIR}" "${SVG_SRC}" >/dev/null 2>&1
  cp -f "${TMP_DIR}/$(basename "${SVG_SRC}").png" "${RAW_PNG}"
fi

if [[ ! -s "${RAW_PNG}" ]]; then
  echo "[generate-icon] ERROR: Rasterized PNG is missing or empty" >&2
  exit 1
fi

# Produce exact 1024x1024 master PNG in Build/ for inspection and iconset generation
sips -s format png -z 1024 1024 "${RAW_PNG}" --out "${ICON_1024_PNG}" >/dev/null

rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"

declare -a ICON_SPECS=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)

for spec in "${ICON_SPECS[@]}"; do
  name="${spec%%:*}"
  size="${spec##*:}"
  sips -s format png -z "${size}" "${size}" "${RAW_PNG}" --out "${ICONSET_DIR}/${name}" >/dev/null
done

rm -f "${ICNS_OUT}"
iconutil -c icns -o "${ICNS_OUT}" "${ICONSET_DIR}"

if [[ ! -s "${ICNS_OUT}" ]]; then
  echo "[generate-icon] ERROR: Failed to compile ${ICNS_OUT}" >&2
  exit 1
fi

ICNS_BYTES="$(stat -f%z "${ICNS_OUT}")"
PNG_BYTES="$(stat -f%z "${ICON_1024_PNG}")"
echo "[generate-icon] Generated ${ICNS_OUT} (${ICNS_BYTES} bytes) and ${ICON_1024_PNG} (${PNG_BYTES} bytes)"
